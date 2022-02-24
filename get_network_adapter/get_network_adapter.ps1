function output ([object] $Obj, [object] $Param, [string] $Script) {
    if ($Obj -and $Param.Cloud -and $Param.Token) {
        $Rtr = Join-Path $env:SystemRoot 'system32\drivers\CrowdStrike\Rtr'
        if ((Test-Path $Rtr -PathType Container) -eq $false) { ni $Rtr -ItemType Directory }
        $Json = $Script -replace '\.ps1', "_$((Get-Date).ToFileTimeUtc()).json"
        $Iwr = @{ Uri = @($Param.Cloud, 'api/v1/ingest/humio-structured/') -join $null; Method = 'post';
            Headers = @{ Authorization = @('Bearer', $Param.Token) -join ' '; ContentType = 'application/json' }}
        $A = @{ script = $Script; host = [System.Net.Dns]::GetHostName() }
        $R = reg query ('HKEY_LOCAL_MACHINE\SYSTEM\CrowdStrike\{9b03c1d9-3138-44ed-9fae-d9f4c034b88d}\{16e0423f-' +
            '7058-48c9-a204-725362b67639}\Default') 2>$null
        if ($R) {
            $A['cid'] = (($R -match 'CU ') -split 'REG_BINARY')[-1].Trim().ToLower()
            $A['aid'] = (($R -match 'AG ') -split 'REG_BINARY')[-1].Trim().ToLower()
        }
        $E = @($Obj).foreach{
            $C = $A.Clone()
            $_.PSObject.Properties | % { $C[$_.Name]=$_.Value }
            ,@{ timestamp = Get-Date -Format o; attributes = $C }
        }
        for ($i = 0; $i -lt ($E | measure).Count; $i += 200) {
            $B = @{ tags = @{ type = 'crowdstrike_falcon_rtr_script' }; events = @($E[$i..($i + 199)]) }
            $Req = try { iwr @Iwr -Body (ConvertTo-Json @($B) -Depth 8 -Compress) -UseBasicParsing } catch {}
            if ($Req.StatusCode -ne 200) {
                ConvertTo-Json @($B) -Depth 8 -Compress >> (Join-Path $Rtr $Json)
            }
        }
    }
    $Obj | ConvertTo-Json -Depth 8 -Compress
}
function parse ([string] $String) {
    $Param = try { $String | ConvertFrom-Json } catch { throw $_ }
    switch ($Param) {
        { $_.Cloud -and $_.Cloud -notmatch '/$' } {
            $_.Cloud += '/'
        }
        { ($_.Cloud -and -not $_.Token) -or ($_.Token -and -not $_.Cloud) } {
            throw "Both 'Cloud' and 'Token' are required when sending results to Humio."
        }
        { $_.Cloud -and $_.Cloud -notmatch '^https://cloud(.(community|us))?.humio.com/$' } {
            throw "'$($_.Cloud)' is not a valid Humio cloud value."
        }
        { $_.Token -and $_.Token -notmatch '^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$' } {
            throw "'$($_.Token)' is not a valid Humio ingest token."
        }
        { $_.Cloud -and $_.Token -and [Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12' } {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            } catch {
                throw $_
            }
        }
    }
    $Param
}
$Param = if ($args[0]) { parse $args[0] }
$Sel = @('Name', 'MacAddress', 'LinkSpeed', 'Virtual', 'Status', 'MediaConnectionState', 'FullDuplex',
    'DriverName', 'DriverVersionString')
$Out = Get-NetAdapter -EA 0 | % {
    $Ip = Get-NetIpAddress -InterfaceIndex $_.IfIndex | select IPAddress, AddressFamily
    $_ | select $Sel | % {
        $_.PSObject.Properties.Add((New-Object PSNoteProperty('Ipv4Address',($Ip | ? {
            $_.AddressFamily -eq 'IPv4' }).IPAddress)))
        $_.PSObject.Properties.Add((New-Object PSNoteProperty('Ipv6Address',($Ip | ? {
            $_.AddressFamily -eq 'IPv6'}).IPAddress)))
        $_
    }
}
output $Out $Param "get_network_adapter.ps1"