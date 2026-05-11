# Node processor - Enhanced with hysteria2, hysteria, TUIC support
# Naming: 【ChromeGo】x-y (x=serial number, y=country)
param([switch]$SkipTest)

$WorkDir = "$PSScriptRoot"
$NodesDir = "$WorkDir\nodes"
$OutputFile = "$WorkDir\result.list"
$RepoUrl = "git@github.com:bang-dream/free-scriptions.git"
$XrayExe = "$WorkDir\xray\xray.exe"
$SingboxExe = "$WorkDir\sing-box\sing-box.exe"

$FakeServers = @("127.", "0.0.0.0", "localhost", "192.168.", "10.", "172.")
$TestUrl = "https://www.gstatic.com/generate_204"

$XrayProtocols = @("vmess", "vless", "ss", "trojan")
$SingboxProtocols = @("hysteria2", "hysteria", "tuic")

# IP geolocation cache
$IpCountryCache = @{}

function Get-CountryFromIp($Ip) {
    if ($IpCountryCache.ContainsKey($Ip)) {
        return $IpCountryCache[$Ip]
    }
    
    if (IsFakeNode($Ip)) {
        return "Local"
    }
    
    try {
        $ApiUrl = "http://ip-api.com/json/" + $Ip + "?fields=countryCode&lang=en"
        $Result = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -TimeoutSec 5
        $Country = $Result.countryCode
        if ($Country) {
            $IpCountryCache[$Ip] = $Country
            return $Country
        }
    } catch {
        try {
            $ApiUrl2 = "https://ipinfo.io/" + $Ip + "/country"
            $Country2 = Invoke-RestMethod -Uri $ApiUrl2 -UseBasicParsing -TimeoutSec 5
            if ($Country2) {
                $IpCountryCache[$Ip] = $Country2
                return $Country2
            }
        } catch {}
    }
    
    $IpCountryCache[$Ip] = "XX"
    return "XX"
}

function IsFakeNode($Server) {
    foreach ($Fake in $FakeServers) {
        if ($Server.StartsWith($Fake)) { return $true }
    }
    return $false
}

function Download-Singbox {
    $SingboxDir = "$WorkDir\sing-box"
    if (Test-Path $SingboxExe) { 
        Write-Host "  sing-box already exists" -ForegroundColor Green
        return $true 
    }
    
    Write-Host "  Downloading sing-box..." -ForegroundColor Yellow
    $ApiUrl = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    try {
        $Release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
        $Version = $Release.tag_name
        $Asset = $Release.assets | Where-Object { $_.name -match "sing-box.*windows.*amd64.*zip" } | Select-Object -First 1
        if (-not $Asset) {
            Write-Host "  ERROR: Could not find sing-box Windows asset" -ForegroundColor Red
            return $false
        }
        
        $DownloadUrl = $Asset.browser_download_url
        $ZipFile = "$SingboxDir\sing-box.zip"
        New-Item -ItemType Directory -Force -Path $SingboxDir | Out-Null
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipFile -UseBasicParsing
        Expand-Archive -Path $ZipFile -DestinationPath $SingboxDir -Force
        Remove-Item $ZipFile -Force
        
        $ExtractedExe = Get-ChildItem "$SingboxDir\*.exe" -Recurse | Where-Object { $_.Name -eq "sing-box.exe" } | Select-Object -First 1
        if ($ExtractedExe) {
            Move-Item $ExtractedExe.FullName $SingboxExe -Force
            Get-ChildItem $SingboxDir -Directory | Remove-Item -Recurse -Force
        }
        
        if (Test-Path $SingboxExe) {
            Write-Host "  sing-box downloaded: $Version" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "  ERROR: Failed to download sing-box: $_" -ForegroundColor Red
        return $false
    }
    return $false
}

function New-NodeObject {
    return @{
        name = ""
        type = ""
        server = ""
        port = 0
        uuid = ""
        password = ""
        alterId = 0
        cipher = "auto"
        network = "tcp"
        tls = $false
        sni = ""
        skipCertVerify = $false
        publicKey = ""
        shortId = ""
        obfs = ""
        obfsPassword = ""
        authStr = ""
        up = ""
        down = ""
        alpn = ""
        congestionController = "bbr"
        udpRelayMode = "native"
        reduceRtt = $true
    }
}

function ExtractValue($Line) {
    $Idx = $Line.IndexOf(':')
    if ($Idx -lt 0) { return "" }
    $Val = $Line.Substring($Idx + 1).Trim()
    if ($Val.StartsWith('"') -and $Val.EndsWith('"')) { $Val = $Val.Substring(1, $Val.Length - 2) }
    if ($Val.StartsWith("'") -and $Val.EndsWith("'")) { $Val = $Val.Substring(1, $Val.Length - 2) }
    return $Val.Trim()
}

function ParseNodeField($Line, $Node, $InSection) {
    $Trimmed = $Line.Trim()
    
    if ($InSection -eq "reality") {
        if ($Trimmed.StartsWith("public-key")) { $Node.publicKey = ExtractValue($Trimmed) }
        elseif ($Trimmed.StartsWith("short-id")) { $Node.shortId = ExtractValue($Trimmed) }
        return
    }
    if ($InSection -eq "hysteria2") {
        if ($Trimmed.StartsWith("obfs-salamander")) { $Node.obfs = ExtractValue($Trimmed) }
        elseif ($Trimmed.StartsWith("obfs-password")) { $Node.obfsPassword = ExtractValue($Trimmed) }
        return
    }
    
    if ($Trimmed.StartsWith("name:")) { $Node.name = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("type:")) { $Node.type = ExtractValue($Trimmed).ToLower() }
    elseif ($Trimmed.StartsWith("server:")) { $Node.server = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("port:")) { 
        $PortStr = ExtractValue($Trimmed)
        try { $Node.port = [int]$PortStr } catch { }
    }
    elseif ($Trimmed.StartsWith("uuid:")) { $Node.uuid = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("password:")) { $Node.password = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("auth:")) { $Node.password = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("auth-str:")) { $Node.authStr = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("alterId:")) { 
        $Val = ExtractValue($Trimmed)
        try { $Node.alterId = [int]$Val } catch { }
    }
    elseif ($Trimmed.StartsWith("cipher:")) { $Node.cipher = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("network:")) { $Node.network = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("tls:")) { $Node.tls = (ExtractValue($Trimmed) -eq "true") }
    elseif ($Trimmed.StartsWith("skip-cert-verify:")) { 
        $Val = ExtractValue($Trimmed)
        $Node.skipCertVerify = ($Val -eq "true")
    }
    elseif ($Trimmed.StartsWith("sni:")) { $Node.sni = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("servername:")) { $Node.sni = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("obfs-salamander:")) { $Node.obfs = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("obfs-password:")) { $Node.obfsPassword = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("up:")) { $Node.up = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("down:")) { $Node.down = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("alpn:")) {
        $Val = ExtractValue($Trimmed)
        if ($Val.StartsWith("[") -and $Val.EndsWith("]")) { $Val = $Val.Substring(1, $Val.Length - 2) }
        $Node.alpn = $Val.Replace('"', '').Replace("'", '').Trim()
    }
    elseif ($Trimmed.StartsWith("congestion-controller:") -or $Trimmed.StartsWith("congestion_controller:")) { 
        $Node.congestionController = ExtractValue($Trimmed).ToLower() 
    }
    elseif ($Trimmed.StartsWith("udp-relay-mode:")) { $Node.udpRelayMode = ExtractValue($Trimmed) }
    elseif ($Trimmed.StartsWith("reduce-rtt:")) { $Node.reduceRtt = (ExtractValue($Trimmed) -eq "true") }
}

function ParseNodesFromYaml($Content) {
    $Nodes = @()
    if (-not $Content) { return $Nodes }
    
    $Lines = $Content -split "`n"
    
    $FirstLines = $Lines | Select-Object -First 10 | Where-Object { $_ -match '^\d+$' }
    if ($FirstLines.Count -ge 5) {
        $Chars = $Lines | Where-Object { $_ -match '^\d+$' } | ForEach-Object { 
            try { [char][int]$_ } catch { }
        }
        $Content = $Chars -join ""
        $Lines = $Content -split "`n"
    }
    
    $InProxies = $false
    $CurrentNode = $null
    $InSection = ""
    
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i]
        $Trimmed = $Line.Trim()
        
        if ($Trimmed -eq "proxies:") { $InProxies = $true; continue }
        
        if ($InProxies -and $Line -match '^[a-zA-Z]' -and $Line -notmatch '^  ' -and $Line -notmatch '^-') {
            if ($CurrentNode -and $CurrentNode.server -and $CurrentNode.port -gt 0) {
                if (-not (IsFakeNode($CurrentNode.server))) { $Nodes += $CurrentNode }
            }
            $CurrentNode = $null
            $InProxies = $false
            $InSection = ""
            continue
        }
        
        if (-not $InProxies) { continue }
        
        if ($Trimmed -eq "reality-opts:") { $InSection = "reality"; continue }
        if ($Trimmed -eq "hysteria2-opts:") { $InSection = "hysteria2"; continue }
        
        if ($InSection -and $Line -match '^  [a-zA-Z]' -and $Line -notmatch '^    ') { $InSection = "" }
        
        if ($Line -match '^  - ' -or $Line -match '^- ') {
            if ($CurrentNode -and $CurrentNode.server -and $CurrentNode.port -gt 0) {
                if (-not (IsFakeNode($CurrentNode.server))) { $Nodes += $CurrentNode }
            }
            $CurrentNode = New-NodeObject
            $InSection = ""
            $AfterDash = if ($Line -match '^  - ') { $Line.Substring(4).Trim() } else { $Line.Substring(2).Trim() }
            if ($AfterDash) { ParseNodeField $AfterDash $CurrentNode "" }
        }
        elseif ($CurrentNode -and $Trimmed -and -not $Trimmed.StartsWith("-")) {
            ParseNodeField $Trimmed $CurrentNode $InSection
        }
    }
    
    if ($CurrentNode -and $CurrentNode.server -and $CurrentNode.port -gt 0) {
        if (-not (IsFakeNode($CurrentNode.server))) { $Nodes += $CurrentNode }
    }
    
    return $Nodes
}

function ConvertNodeToV2rayNString($Node, $SerialNum, $Country) {
    if (-not $Node.server -or $Node.port -le 0) { return $null }
    
    $Type = $Node.type
    $Addr = $Node.server
    $Port = $Node.port
    $Pass = if ($Node.password) { $Node.password } elseif ($Node.uuid) { $Node.uuid } else { "" }
    
    # New naming format: 【ChromeGo】number-country
    $AliasName = "【ChromeGo】" + $SerialNum + "-" + $Country
    # Use proper URL encoding
    $NameEncoded = [uri]::EscapeDataString($AliasName)
    $Amp = [char]38
    
    if ($Type -eq "vmess") {
        if (-not $Node.uuid) { return $null }
        $J = @{
            v = "2"
            ps = $AliasName
            add = $Addr
            port = $Port.ToString()
            id = $Node.uuid
            aid = $Node.alterId.ToString()
            scy = $Node.cipher
            net = $Node.network
            type = "none"
            tls = if ($Node.tls) { "tls" } else { "" }
            sni = $Node.sni
            host = ""
            path = ""
        }
        $JsonStr = $J | ConvertTo-Json -Compress
        $B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($JsonStr))
        return "vmess://" + $B64
    }
    
    if ($Type -eq "vless") {
        if (-not $Node.uuid) { return $null }
        $NetType = if ($Node.network) { $Node.network } else { "tcp" }
        $Params = @("type=" + $NetType)
        if ($Node.publicKey) {
            $Params += "security=reality"
            $Params += "pbk=" + $Node.publicKey
            if ($Node.shortId) { $Params += "sid=" + $Node.shortId }
        } elseif ($Node.tls) { $Params += "security=tls" }
        if ($Node.sni) { $Params += "sni=" + $Node.sni }
        $ParamStr = $Params -join $Amp
        return "vless://" + $Node.uuid + "@" + $Addr + ":" + $Port + "?" + $ParamStr + "#" + $NameEncoded
    }
    
    if ($Type -eq "ss") {
        if (-not $Node.cipher -or -not $Pass) { return $null }
        $UserInfo = $Node.cipher + ":" + $Pass
        $B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UserInfo))
        return "ss://" + $B64 + "@" + $Addr + ":" + $Port + "#" + $NameEncoded
    }
    
    if ($Type -eq "trojan") {
        if (-not $Pass) { return $null }
        $Sni = if ($Node.sni) { $Node.sni } else { $Addr }
        return "trojan://" + $Pass + "@" + $Addr + ":" + $Port + "?sni=" + $Sni + "#" + $NameEncoded
    }
    
    if ($Type -eq "hysteria2") {
        if (-not $Pass) { return $null }
        $Params = @()
        if ($Node.sni) { $Params += "sni=" + $Node.sni }
        if ($Node.obfs) { $Params += "obfs=" + $Node.obfs }
        if ($Node.obfsPassword) { $Params += "obfs-password=" + $Node.obfsPassword }
        $ParamStr = if ($Params.Count -gt 0) { "?" + ($Params -join $Amp) } else { "" }
        return "hysteria2://" + $Pass + "@" + $Addr + ":" + $Port + $ParamStr + "#" + $NameEncoded
    }
    
    if ($Type -eq "hysteria") {
        $Auth = if ($Node.authStr) { $Node.authStr } elseif ($Node.password) { $Node.password } else { "" }
        if (-not $Auth) { return $null }
        $Params = @("auth=" + $Auth)
        if ($Node.up) { $Params += "up=" + $Node.up }
        if ($Node.down) { $Params += "down=" + $Node.down }
        if ($Node.alpn) { $Params += "alpn=" + $Node.alpn }
        if ($Node.sni) { $Params += "sni=" + $Node.sni }
        $ParamStr = $Params -join $Amp
        return "hysteria://" + $Addr + ":" + $Port + "?" + $ParamStr + "#" + $NameEncoded
    }
    
    if ($Type -eq "tuic") {
        if (-not $Node.uuid -or -not $Pass) { return $null }
        $Params = @("congestion_controller=" + $Node.congestionController)
        if ($Node.alpn) { $Params += "alpn=" + $Node.alpn }
        if ($Node.sni) { $Params += "sni=" + $Node.sni }
        if ($Node.udpRelayMode) { $Params += "udp_relay_mode=" + $Node.udpRelayMode }
        $ParamStr = $Params -join $Amp
        return "tuic://" + $Node.uuid + ":" + $Pass + "@" + $Addr + ":" + $Port + "?" + $ParamStr + "#" + $NameEncoded
    }
    
    return $null
}

function New-XrayConfig($Node, $LocalPort) {
    $Inbound = @{ port = $LocalPort; protocol = "socks"; settings = @{ auth = "noauth"; udp = $true } }
    $Outbound = $null
    
    if ($Node.type -eq "vmess") {
        if (-not $Node.uuid) { return $null }
        $Outbound = @{
            protocol = "vmess"
            settings = @{ vnext = @(@{ address = $Node.server; port = $Node.port; users = @(@{ id = $Node.uuid; alterId = $Node.alterId; security = $Node.cipher }) }) }
            streamSettings = @{ network = $Node.network; security = if ($Node.tls) { "tls" } else { "none" } }
        }
        if ($Node.tls) { $Outbound.streamSettings.tlsSettings = @{ allowInsecure = $true; serverName = $Node.sni } }
    }
    elseif ($Node.type -eq "vless") {
        if (-not $Node.uuid) { return $null }
        $Outbound = @{
            protocol = "vless"
            settings = @{ vnext = @(@{ address = $Node.server; port = $Node.port; users = @(@{ id = $Node.uuid; encryption = "none" }) }) }
            streamSettings = @{ network = $Node.network; security = if ($Node.tls) { "tls" } else { "none" } }
        }
        if ($Node.publicKey) {
            $Outbound.streamSettings.security = "reality"
            $Outbound.streamSettings.realitySettings = @{ show = $false; fingerprint = "chrome"; serverName = $Node.sni; publicKey = $Node.publicKey; shortId = $Node.shortId }
        } elseif ($Node.tls) { $Outbound.streamSettings.tlsSettings = @{ allowInsecure = $true; serverName = $Node.sni } }
    }
    elseif ($Node.type -eq "ss") {
        if (-not $Node.password -or -not $Node.cipher) { return $null }
        $Outbound = @{ protocol = "shadowsocks"; settings = @{ servers = @(@{ address = $Node.server; port = $Node.port; password = $Node.password; method = $Node.cipher }) } }
    }
    elseif ($Node.type -eq "trojan") {
        if (-not $Node.password) { return $null }
        $Outbound = @{
            protocol = "trojan"
            settings = @{ servers = @(@{ address = $Node.server; port = $Node.port; password = $Node.password }) }
            streamSettings = @{ network = "tcp"; security = "tls"; tlsSettings = @{ allowInsecure = $true; serverName = $Node.sni } }
        }
    }
    
    if (-not $Outbound) { return $null }
    return @{ inbounds = @($Inbound); outbounds = @($Outbound) } | ConvertTo-Json -Depth 10
}

function New-SingboxConfig($Node, $LocalPort) {
    $Outbound = $null
    
    if ($Node.type -eq "hysteria2") {
        if (-not $Node.password) { return $null }
        $Outbound = @{
            type = "hysteria2"
            tag = "proxy"
            server = $Node.server
            server_port = $Node.port
            password = $Node.password
            tls = @{ enabled = $true; server_name = $Node.sni; insecure = $Node.skipCertVerify }
        }
        if ($Node.obfs -and $Node.obfsPassword) { $Outbound.obfs = @{ type = $Node.obfs; password = $Node.obfsPassword } }
    }
    elseif ($Node.type -eq "hysteria") {
        $Auth = if ($Node.authStr) { $Node.authStr } elseif ($Node.password) { $Node.password } else { "" }
        if (-not $Auth) { return $null }
        $AlpnList = if ($Node.alpn) { @($Node.alpn.Split(',').Trim()) } else { @("h3") }
        $UpMbps = if ($Node.up) { [int]($Node.up -replace '[^\d]', '') } else { 100 }
        $DownMbps = if ($Node.down) { [int]($Node.down -replace '[^\d]', '') } else { 100 }
        $Outbound = @{
            type = "hysteria"
            tag = "proxy"
            server = $Node.server
            server_port = $Node.port
            auth = $Auth
            up_mbps = $UpMbps
            down_mbps = $DownMbps
            tls = @{ enabled = $true; server_name = $Node.sni; insecure = $Node.skipCertVerify; alpn = $AlpnList }
        }
    }
    elseif ($Node.type -eq "tuic") {
        if (-not $Node.uuid -or -not $Node.password) { return $null }
        $AlpnList = if ($Node.alpn) { @($Node.alpn.Split(',').Trim()) } else { @("h3") }
        $Outbound = @{
            type = "tuic"
            tag = "proxy"
            server = $Node.server
            server_port = $Node.port
            uuid = $Node.uuid
            password = $Node.password
            congestion_control = $Node.congestionController
            udp_relay_mode = $Node.udpRelayMode
            zero_rtt_handshake = $Node.reduceRtt
            tls = @{ enabled = $true; server_name = $Node.sni; insecure = $Node.skipCertVerify; alpn = $AlpnList }
        }
    }
    
    if (-not $Outbound) { return $null }
    return @{
        log = @{ level = "warn" }
        inbounds = @(@{ type = "mixed"; tag = "mixed-in"; listen = "127.0.0.1"; listen_port = $LocalPort })
        outbounds = @($Outbound)
    } | ConvertTo-Json -Depth 10
}

function Test-NodeWithProxy($Node, $ConfigStr, $ProxyExe, $LocalPort) {
    $ConfigFile = "$env:TEMP\proxy-test-$LocalPort.json"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ConfigFile, $ConfigStr, $utf8NoBom)
    
    $Process = Start-Process -FilePath $ProxyExe -ArgumentList "run", "-c", $ConfigFile -PassThru -WindowStyle Hidden
    
    $WaitTime = if ($SingboxProtocols -contains $Node.type) { 1500 } else { 800 }
    Start-Sleep -Milliseconds $WaitTime
    
    if ($Process.HasExited) {
        Remove-Item $ConfigFile -Force -ErrorAction SilentlyContinue
        return @{ success = $false; reason = "startup failed (exit: $($Process.ExitCode))" }
    }
    
    $HttpCode = curl.exe --socks5-hostname "127.0.0.1:$LocalPort" -m 10 -k -s -o "$env:TEMP\proxy-out.txt" -w "%{http_code}" $TestUrl 2>&1
    
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    Remove-Item $ConfigFile, "$env:TEMP\proxy-out.txt" -Force -ErrorAction SilentlyContinue
    
    if ($HttpCode -match "200|204") { return @{ success = $true; code = $HttpCode } }
    return @{ success = $false; reason = "HTTP $HttpCode" }
}

function PushToGitHub($File, $Repo, $Dir) {
    $RepoDir = "$Dir\repo"
    if (Test-Path $RepoDir) {
        Push-Location $RepoDir
        git fetch origin 2>&1 | Out-Null
        git reset --hard origin/main 2>&1 | Out-Null
        Pop-Location
    } else {
        git clone $Repo $RepoDir 2>&1 | Out-Null
    }
    if (-not (Test-Path $RepoDir)) { Write-Host "Clone failed" -ForegroundColor Red; return }
    Copy-Item $File "$RepoDir\result.list" -Force
    Push-Location $RepoDir
    git add result.list 2>&1 | Out-Null
    $CommitMsg = "Update nodes - " + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    git commit -m $CommitMsg 2>&1 | Out-Null
    git push origin main 2>&1 | Out-Null
    Pop-Location
    Write-Host "Pushed to GitHub!" -ForegroundColor Green
}

# MAIN
Write-Host "=== Node Sync (Enhanced: hysteria2, hysteria, TUIC) ===" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

Write-Host "Step 0: Checking tools..."
if (-not (Test-Path $XrayExe)) { Write-Host "ERROR: xray.exe not found" -ForegroundColor Red; exit 1 }
Write-Host "  xray: OK" -ForegroundColor Green
$HasSingbox = Download-Singbox

Write-Host "Step 1: Parsing YAML..."
$AllNodes = @()
$Files = Get-ChildItem "$NodesDir\*.yaml" -ErrorAction SilentlyContinue
foreach ($File in $Files) {
    $Content = Get-Content $File.FullName -Raw -ErrorAction SilentlyContinue
    $AllNodes += ParseNodesFromYaml $Content
}
Write-Host "  Parsed: $($AllNodes.Count) nodes"

$TypeCounts = @{}
foreach ($Node in $AllNodes) {
    $T = $Node.type
    if ($TypeCounts.ContainsKey($T)) { $TypeCounts[$T] = $TypeCounts[$T] + 1 }
    else { $TypeCounts[$T] = 1 }
}
Write-Host "  Types:" -NoNewline
foreach ($Kv in $TypeCounts.GetEnumerator() | Sort-Object Value -Descending) { Write-Host " $($Kv.Key)=$($Kv.Value)" -NoNewline }
Write-Host ""

Write-Host "Step 2: Deduplicating..."
$UniqueNodes = @{}
foreach ($Node in $AllNodes) {
    $Key = $Node.type + "|" + $Node.server + ":" + $Node.port
    if (-not $UniqueNodes.ContainsKey($Key)) { $UniqueNodes[$Key] = $Node }
}
$DedupedNodes = @($UniqueNodes.Values)
Write-Host "  Unique: $($DedupedNodes.Count)"

$UniqueTypeCounts = @{}
foreach ($Node in $DedupedNodes) {
    $T = $Node.type
    if ($UniqueTypeCounts.ContainsKey($T)) { $UniqueTypeCounts[$T] = $UniqueTypeCounts[$T] + 1 }
    else { $UniqueTypeCounts[$T] = 1 }
}
Write-Host "  Unique types:" -NoNewline
foreach ($Kv in $UniqueTypeCounts.GetEnumerator() | Sort-Object Value -Descending) { Write-Host " $($Kv.Key)=$($Kv.Value)" -NoNewline }
Write-Host ""

$AllSupportedTypes = $XrayProtocols + $SingboxProtocols
$SupportedNodes = $DedupedNodes | Where-Object { $AllSupportedTypes -contains $_.type }
$XrayNodes = $SupportedNodes | Where-Object { $XrayProtocols -contains $_.type }
$SingboxNodes = $SupportedNodes | Where-Object { $SingboxProtocols -contains $_.type }
Write-Host "  Xray (vmess/vless/ss/trojan): $($XrayNodes.Count)"
Write-Host "  Singbox (hysteria2/hysteria/tuic): $($SingboxNodes.Count)"

$SortedNodes = @($SingboxNodes) + @($XrayNodes)
Write-Host "  Sorted: $($SingboxNodes.Count) sing-box first, then $($XrayNodes.Count) xray"

Write-Host "Step 3: Testing proxies..."
if ($SkipTest) {
    Write-Host "  SKIP TEST - including all" -ForegroundColor Yellow
    $ValidNodeObjects = @($SortedNodes)
    $Stats = @{ xray_ok=$XrayNodes.Count; singbox_ok=$SingboxNodes.Count; xray_fail=0; singbox_fail=0 }
} else {
    Write-Host "  Test URL: $TestUrl"
    $ValidNodeObjects = @()
    $Stats = @{ xray_ok=0; singbox_ok=0; xray_fail=0; singbox_fail=0 }
    $TestIndex = 0
    
    Stop-Process -Name "xray" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "sing-box" -Force -ErrorAction SilentlyContinue
    
    foreach ($Node in $SortedNodes) {
        $TestIndex++
        $TestPort = Get-Random -Minimum 20000 -Maximum 40000
        
        if ($XrayProtocols -contains $Node.type) {
            $Config = New-XrayConfig $Node $TestPort
            if (-not $Config) { Write-Host "  [$TestIndex] SKIP: $($Node.server):$($Node.port) [$($Node.type)]" -ForegroundColor Yellow; continue }
            $Result = Test-NodeWithProxy $Node $Config $XrayExe $TestPort
            if ($Result.success) { 
                $ValidNodeObjects += $Node
                Write-Host "  [$TestIndex] OK: $($Node.server):$($Node.port) [$($Node.type)]" -ForegroundColor Green
                $Stats.xray_ok++ 
            }
            else { Write-Host "  [$TestIndex] FAIL: $($Node.server):$($Node.port) [$($Node.type)] - $($Result.reason)" -ForegroundColor Red; $Stats.xray_fail++ }
        }
        elseif ($SingboxProtocols -contains $Node.type) {
            if (-not $HasSingbox) { 
                $ValidNodeObjects += $Node
                Write-Host "  [$TestIndex] INCLUDE: $($Node.server):$($Node.port) [$($Node.type)] (no sing-box)" -ForegroundColor Yellow
                $Stats.singbox_ok++
                continue 
            }
            $Config = New-SingboxConfig $Node $TestPort
            if (-not $Config) { Write-Host "  [$TestIndex] SKIP: $($Node.server):$($Node.port) [$($Node.type)]" -ForegroundColor Yellow; continue }
            $Result = Test-NodeWithProxy $Node $Config $SingboxExe $TestPort
            if ($Result.success) { 
                $ValidNodeObjects += $Node
                Write-Host "  [$TestIndex] OK: $($Node.server):$($Node.port) [$($Node.type)]" -ForegroundColor Green
                $Stats.singbox_ok++ 
            }
            else { Write-Host "  [$TestIndex] FAIL: $($Node.server):$($Node.port) [$($Node.type)] - $($Result.reason)" -ForegroundColor Red; $Stats.singbox_fail++ }
            Start-Sleep -Milliseconds 500
            continue
        }
        Start-Sleep -Milliseconds 100
    }
}

Write-Host ""
Write-Host "  Xray: ok=$($Stats.xray_ok), fail=$($Stats.xray_fail)" -ForegroundColor Cyan
Write-Host "  Singbox: ok=$($Stats.singbox_ok), fail=$($Stats.singbox_fail)" -ForegroundColor Cyan
Write-Host "  Total valid: $($ValidNodeObjects.Count)" -ForegroundColor Green

Write-Host "Step 4: Getting IP geolocation and converting..."
$FinalNodeList = @()
$SerialNum = 1

foreach ($Node in $ValidNodeObjects) {
    $Country = Get-CountryFromIp $Node.server
    Write-Host ("  Node #" + $SerialNum + ": " + $Node.server + " -> " + $Country + " [" + $Node.type + "]")
    
    $Str = ConvertNodeToV2rayNString $Node $SerialNum $Country
    if ($Str) {
        $FinalNodeList += $Str
        $SerialNum++
    }
}

Write-Host "  Converted: $($FinalNodeList.Count)" -ForegroundColor Green

Write-Host "Step 5: Saving..."
$HeaderLines = @(
    "# ChromeGo Node List",
    "# Updated: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
    "# Total: " + $FinalNodeList.Count,
    "# Format: 【ChromeGo】number-country (x=serial, y=country)",
    "# Protocols: vmess, vless, ss, trojan, hysteria2, hysteria, tuic",
    ""
)
$Header = $HeaderLines -join "`n"
$Header | Out-File $OutputFile -Encoding UTF8 -Force
$FinalNodeList | Out-File $OutputFile -Encoding UTF8 -Append
Write-Host "  Saved: $OutputFile"

Write-Host "Step 6: Pushing to GitHub..."
PushToGitHub $OutputFile $RepoUrl $WorkDir

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Valid nodes: $($FinalNodeList.Count)"
