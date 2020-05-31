﻿using module ..\Include.psm1

param(
    [PSCustomObject]$Wallets,
    [PSCustomObject]$Params,
    [alias("WorkerName")]
    [String]$Worker,
    [TimeSpan]$StatSpan,
    [String]$DataWindow = "estimate_current",
    [Bool]$InfoOnly = $false,
    [Bool]$AllowZero = $false,
    [String]$StatAverage = "Minute_10"
)

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

[hashtable]$Pool_RegionsTable = @{}
@("eu") | Foreach-Object {$Pool_RegionsTable.$_ = Get-Region $_}

$Pools_Data = @(
    [PSCustomObject]@{symbol = "ATOMI"; port = 3334; fee = 1.0; rpc = "atomi"; region = @("eu")}
    [PSCustomObject]@{symbol = "BEAM";  port = 3334; fee = 1.0; rpc = "beam"; region = @("eu")}
    [PSCustomObject]@{symbol = "XGM";   port = 3334; fee = 1.0; rpc = "grimm"; region = @("eu")}
)

$Pools_Data | Where-Object {$Wallets."$($_.symbol)" -or $InfoOnly} | ForEach-Object {
    $Pool_Coin      = Get-Coin $_.symbol
    $Pool_Currency  = $_.symbol
    $Pool_Fee       = $_.fee
    $Pool_Port      = $_.port
    $Pool_RpcPath   = $_.rpc
    $Pool_Regions   = $_.region

    $Pool_Divisor   = if ($_.divisor) {$_.divisor} else {1}
    $Pool_HostPath  = if ($_.host) {$_.host} else {$Pool_RpcPath}

    $Pool_Algorithm_Norm = Get-Algorithm $Pool_Coin.algo

    $Pool_Request  = [PSCustomObject]@{}
    $Pool_RequestBlocks = [PSCustomObject]@{}

    $ok = $true
    if (-not $InfoOnly) {
        try {
            $Pool_Request = Invoke-RestMethodAsync "https://$($Pool_RpcPath).sunpool.top/pool-info.php?miningpoolstats" -tag $Name -timeout 15 -cycletime 120
            if ($Pool_Request.coin -ne $Pool_Currency) {$ok = $false}
            else {
                $Pool_RequestBlocks = Invoke-RestMethodAsync "https://$($Pool_RpcPath).sunpool.top/pool-stats.php" -tag $Name -timeout 15 -cycletime 120
                if (-not $Pool_RequestBlocks) {$ok = $false}
            }
        }
        catch {
            if ($Error.Count){$Error.RemoveAt(0)}
            $ok = $false
        }
        if (-not $ok) {
            Write-Log -Level Warn "Pool API ($Name) for $Pool_Currency has failed. "
        }
    }

    if ($ok -and -not $InfoOnly) {
        $Pool_Fee = $Pool_Request.feePercent

        $timestamp24h = $Pool_Request.timestampMilliSeconds - 86400000
        $blocks_measure = (([regex]'timestampToDate\((\d+)\)').Matches($Pool_RequestBlocks)).Foreach({$_.Groups[1].Value}).Where({$_ -ge $timestamp24h}) | Measure-Object -Minimum -Maximum        

        $Pool_BLK = [int]$($(if ($blocks_measure.Count -gt 1 -and ($blocks_measure.Maximum - $blocks_measure.Minimum)) {86400000/($blocks_measure.Maximum - $blocks_measure.Minimum)} else {1})*$blocks_measure.Count)
        $Pool_TSL = [Math]::Round(($Pool_Request.timestampMilliSeconds - ($Pool_Request.lastBlocksFound.timestampMilliseconds | Measure-Object -Maximum).Maximum)/1000)

        $Stat = Set-Stat -Name "$($Name)_$($Pool_Currency)_Profit" -Value 0 -Duration $StatSpan -HashRate $Pool_Request.hashrate -BlockRate $Pool_BLK -ChangeDetection $false -Quiet
        if (-not $Stat.HashRate_Live -and -not $AllowZero) {return}
    }
    
    if ($ok -or $InfoOnly) {
        $Pool_SSL = $true
        foreach ($Pool_Region in $Pool_Regions) {
            [PSCustomObject]@{
                Algorithm     = $Pool_Algorithm_Norm
				Algorithm0    = $Pool_Algorithm_Norm
                CoinName      = $Pool_Coin.Name
                CoinSymbol    = $Pool_Currency
                Currency      = $Pool_Currency
                Price         = 0
                StablePrice   = 0
                MarginOfError = 0
                Protocol      = "stratum+$(if ($Pool_SSL) {"ssl"} else {"tcp"})"
                Host          = "$($Pool_HostPath)-$($Region).sunpool.top"
                Port          = $Pool_Port
                User          = "$($Wallets.$Pool_Currency).{workername:$Worker}"
                Pass          = "$(if ($Email) {$Email} else {"x"})"
                Region        = $Pool_RegionsTable[$Pool_Region]
                SSL           = $Pool_SSL
                Updated       = $Stat.Updated
                PoolFee       = $Pool_Fee
                Workers       = $Pool_Request.pools.$Pool_RpcPath.workerCount
                Hashrate      = $Stat.HashRate_Live
                TSL           = $Pool_TSL
                BLK           = $Stat.BlockRate_Average
                WTM           = $true
                Name          = $Name
                Penalty       = 0
                PenaltyFactor = 1
				Disabled      = $false
				HasMinerExclusions = $false
				Price_Bias    = 0.0
				Price_Unbias  = 0.0
                Wallet        = $Wallets.$Pool_Currency
                Worker        = "{workername:$Worker}"
                Email         = $Email
            }
        }
    }
}
