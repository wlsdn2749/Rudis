# Rudis 에코 테스트 클라이언트 (PowerShell)
#
# 쓰는 법 두 가지:
#
# (A) 그냥 실행 → 대화형 에코 클라이언트
#   .\client\echo-client.ps1
#   서버 안 떠 있으면 재시도 물어봄. 입력한 줄을 보내고 응답을 찍음.
#   빈 줄 = 응답만 읽기(EOF 확인), /q = 종료
#
# (B) dot-source (앞의 점 필수) → 함수만 불러와서 직접 조합
#   . .\client\echo-client.ps1
#
# (B) 기본 사용:
#   $c = Connect-Rudis                 # 127.0.0.1:6379
#   Send-Line $c 'hello'               # 한 줄 보내고 (CRLF 붙음) 응답 한 줄 읽음
#   Read-Line $c                       # 응답만 한 줄 읽음.
#                                      #   $null 조용히 → EOF, 서버가 정상 종료(FIN)
#                                      #   노란 'read failed' → RST, 서버가 비정상 종료
#                                      #   '' (빈 문자열) → 0.5초 안에 아무것도 안 옴
#   Close-Rudis $c
#
# RESP 단계(Day 5+) 용:
#   Send-Raw  $c "*1`r`n`$4`r`nPING`r`n"   # 문자열을 바이트 그대로 전송 (줄바꿈 안 붙임)
#   Send-Bytes $c 0x2B,0x4F,0x4B,0x0D,0x0A # 바이트 배열 직접 전송 (프레임 쪼개 보내기)
#   Read-Raw  $c                       # 지금 도착해 있는 바이트 전부 (0.5초 타임아웃)
#   Show-Raw  (Read-Raw $c)            # \r \n 을 눈에 보이게 출력
#
# 여러 클라이언트: $a = Connect-Rudis; $b = Connect-Rudis  (창 하나에서도 됨)

$script:Enc = [Text.UTF8Encoding]::new($false)

# IOException 이 타임아웃인지(서버가 아직 안 보냄) 진짜 끊김(RST 등)인지 구분
function Test-Timeout {
    param($ErrorRecord)
    $inner = $ErrorRecord.Exception.InnerException
    return ($inner -is [Net.Sockets.SocketException] -and $inner.SocketErrorCode -eq 'TimedOut')
}

function Write-Fail {
    param([string]$What, $ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    if ($ErrorRecord.Exception.InnerException) { $msg = $ErrorRecord.Exception.InnerException.Message }
    Write-Host "$What failed: $msg" -ForegroundColor Yellow
}

function Connect-Rudis {
    param(
        [string]$Address = '127.0.0.1',
        [int]$Port = 6379
    )
    try {
        $client = [Net.Sockets.TcpClient]::new($Address, $Port)
    } catch {
        # 서버가 안 떠 있거나(거부) 종료된 뒤 — 에러로 멈추지 않고 알리기만
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        Write-Host "connect failed: ${Address}:${Port} - $msg" -ForegroundColor Yellow
        return $null
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout = 500
    Write-Host "connected: ${Address}:${Port}" -ForegroundColor DarkGray
    [pscustomobject]@{
        Client = $client
        Stream = $stream
    }
}

function Close-Rudis {
    param($Conn)
    if (-not $Conn) { Write-Host 'not connected' -ForegroundColor Yellow; return }
    $Conn.Stream.Dispose()
    $Conn.Client.Dispose()
}

function Send-Raw {
    param(
        $Conn,
        [Parameter(Mandatory)] [string]$Text
    )
    if (-not $Conn) { Write-Host 'not connected' -ForegroundColor Yellow; return }
    $bytes = $script:Enc.GetBytes($Text)
    try {
        $Conn.Stream.Write($bytes, 0, $bytes.Length)
        $Conn.Stream.Flush()
    } catch [IO.IOException] {
        Write-Fail 'send' $_
    }
}

function Send-Bytes {
    param(
        $Conn,
        [Parameter(Mandatory)] [byte[]]$Bytes
    )
    if (-not $Conn) { Write-Host 'not connected' -ForegroundColor Yellow; return }
    try {
        $Conn.Stream.Write($Bytes, 0, $Bytes.Length)
        $Conn.Stream.Flush()
    } catch [IO.IOException] {
        Write-Fail 'send' $_
    }
}

# 한 줄 읽기: \n 까지 바이트 단위로 읽고 \r\n 제거.
# 서버가 연결을 닫으면(EOF) $null 반환. 타임아웃이면 지금까지 읽은 것 반환.
function Read-Line {
    param($Conn)
    if (-not $Conn) { Write-Host 'not connected' -ForegroundColor Yellow; return }
    $buf = [Collections.Generic.List[byte]]::new()
    $one = [byte[]]::new(1)
    while ($true) {
        try {
            $n = $Conn.Stream.Read($one, 0, 1)
        } catch [IO.IOException] {
            if (Test-Timeout $_) {
                # ReadTimeout — 서버가 아직 안 보냄
                if ($buf.Count -eq 0) { return '' }
                break
            }
            # RST 등 — 서버가 비정상 종료 (우아한 종료 실패)
            Write-Fail 'read' $_
            return $null
        }
        if ($n -eq 0) {
            # EOF: 서버가 FIN 을 보냈다 = 정상 종료 (아무 메시지 없이 $null)
            if ($buf.Count -eq 0) { return $null }
            break
        }
        if ($one[0] -eq 0x0A) { break }
        $buf.Add($one[0])
    }
    $line = $script:Enc.GetString($buf.ToArray())
    return $line.TrimEnd("`r")
}

function Send-Line {
    param(
        $Conn,
        [Parameter(Mandatory)] [string]$Text
    )
    if (-not $Conn) { Write-Host 'not connected' -ForegroundColor Yellow; return }
    Send-Raw $Conn ($Text + "`r`n")
    Read-Line $Conn
}

# 도착해 있는 바이트 전부 읽기 (타임아웃까지). RESP 응답 전체를 볼 때.
function Read-Raw {
    param($Conn)
    if (-not $Conn) { Write-Host 'not connected' -ForegroundColor Yellow; return }
    $chunk = [byte[]]::new(4096)
    $all = [Collections.Generic.List[byte]]::new()
    while ($true) {
        try {
            $n = $Conn.Stream.Read($chunk, 0, $chunk.Length)
        } catch [IO.IOException] {
            if (-not (Test-Timeout $_)) { Write-Fail 'read' $_ }
            break
        }
        if ($n -eq 0) { break }
        $all.AddRange([byte[]]$chunk[0..($n - 1)])
        if (-not $Conn.Stream.DataAvailable) { break }
    }
    return $script:Enc.GetString($all.ToArray())
}

# \r \n 을 문자로 보여줌. RESP 디버깅용.
function Show-Raw {
    param([AllowEmptyString()] [string]$Text)
    if ($null -eq $Text) { return '<null>' }
    $Text.Replace("`r", '\r').Replace("`n", '\n')
}


# ─────────────────────────────────────────────
# 대화형 모드: dot-source 가 아니라 직접 실행됐을 때만
# ─────────────────────────────────────────────
if ($MyInvocation.InvocationName -ne '.') {

    Write-Host "Rudis echo client  (/q 종료, 빈 줄 = 응답만 읽기)" -ForegroundColor Cyan

    $conn = $null
    try {
    while ($true) {
        # ── 연결 (안 되면 재시도 물어봄, 창 안 닫힘)
        while (-not $conn) {
            $conn = Connect-Rudis
            if (-not $conn) {
                $ans = Read-Host "서버가 응답하지 않음. Enter=재시도, q=종료"
                if ($ans -eq 'q') { return }
            }
        }

        # ── 입력 → 전송 → 응답
        $line = Read-Host ">"
        if ($line -eq '/q') { Close-Rudis $conn; return }

        if ($line -eq '') {
            $resp = Read-Line $conn
        } else {
            $resp = Send-Line $conn $line
        }

        if ($null -eq $resp) {
            Write-Host "server closed the connection" -ForegroundColor DarkYellow
            Close-Rudis $conn
            $conn = $null          # 다음 루프에서 재연결 시도
            continue
        }
        if ($resp -eq '') {
            Write-Host "(no response in 0.5s)" -ForegroundColor DarkGray
        } else {
            Write-Host "< $resp" -ForegroundColor Green
        }
    }
    } catch {
        # 예상 못 한 에러 — 창이 바로 닫히지 않게 붙잡아 둠
        Write-Host $_ -ForegroundColor Red
        Read-Host "Enter 를 누르면 종료"
    }
}
