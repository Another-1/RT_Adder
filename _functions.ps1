function Send-TGMessage ( $message, $token, $chat_id ) {
    $payload = @{
        "chat_id"                  = $chat_id
        "parse_mode"               = 'html'
        "disable_web_page_preview" = $true
        "text"                     = $message
    }
    
    Invoke-WebRequest -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $token) -Method Post  -ContentType "application/json;charset=utf-8" -Body (ConvertTo-Json -Compress -InputObject $payload) | Out-Null
}

function Send-TGReport ( $refreshed, $added, $obsolete, $token, $chat_id ) {
    $message = ''
    $first = $true
    foreach ( $key in $refreshed.Keys ) {
        if ( !$first ) { $message += "`n`n" }
        $first = $false
        $message += "Обновлены в клиенте $key :"
        $refreshed[$key] | ForEach-Object { $message += "`n$_" }
    }

    if ( $message -ne '' ) { $message += "`n`n" }
    $first = $true
    foreach ( $key in $added.Keys ) {
        if ( !$first ) { $message += "`n`n" }
        $first = $false
        $message += "Добавлены в клиент $key :"
        $added[$key] | ForEach-Object { $message += "`n$_" }
    }

    if ( $message -ne '' ) { $message += "`n`n" }
    $first = $true
    foreach ( $key in $obsolete.Keys ) {
        if ( !$first ) { $message += "`n`n" }
        $first = $false
        $message += "Лишние в клиенте $key :"
        $obsolete[$key] | ForEach-Object { $message += "`n$_" }
    }

    Send-TGMessage $message $token $chat_id
}

function Initialize-Client ($client) {
    if ( !$client.sid ) {
        $logindata = @{
            username = $client.login
            password = $client.password
        }
        $loginheader = @{ Referer = 'http://' + $client.IP + ':' + $client.Port }
        try {
            Write-Host ( 'Авторизуемся в клиенте ' + $client.Name )
            $url = $client.IP + ':' + $client.Port + '/api/v2/auth/login'
            $result = Invoke-WebRequest -Method POST -Uri $url -Headers $loginheader -Body $logindata -SessionVariable sid
            if ( $result.StatusCode -ne 200 ) {
                throw 'You are banned.'
            }
            if ( $result.Content -ne 'Ok.') {
                throw $result.Content
            }
            $client.sid = $sid
        }
        catch {
            if ( !$Retry ) {
                Write-Host ( '[client] Не удалось авторизоваться в клиенте, прерываем. Ошибка: {0}.' -f $Error[0] ) -ForegroundColor Red
                Exit
            }
        }
    }
}

function  Get-Torrents ( $client, $disk = '', $Completed = $true, $hash = $nul, $client_key ) {
    $Params = @{}
    if ( $Completed ) {
        $Params.filter = 'completed'
    }
    if ( $nul -ne $hash ) {
        $Params.hashes = $hash
        Write-Host ( 'Получаем имя добавленной раздачи из клиента ' + $client.Name )
    }
    else { Write-Host ( 'Получаем список раздач от клиента ' + $client.Name ) }
    if ( $disk -ne '') { $dsk = $disk + ':\\' } else { $dsk = '' }
    while ( $true ) {
        try {
            $torrents_list = ( Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/info' ) -WebSession $client.sid -Body $params ).Content | ConvertFrom-Json | `
                Select-Object name, hash, save_path, content_path, category, state, @{ N = 'topic_id'; E = { $nul } }, @{ N = 'client_key'; E = { $client_key } } | Where-Object { $_.save_path -match ('^' + $dsk ) }
        }
        catch { exit }
        return $torrents_list
    }
}

function Get-TopicIDs ( $client, $torrent_list ) {
    Write-Host 'Ищем ID'
    $torrent_list | ForEach-Object {
        if ( $nul -ne $tracker_torrents ) { $_.topic_id = $tracker_torrents[$_.hash.toUpper()].id }
        if ( $nul -eq $_.topic_id ) {
            $Params = @{ hash = $_.hash }
            try {
                $comment = ( Invoke-WebRequest -uri ( $client.IP + ':' + $client.Port + '/api/v2/torrents/properties' ) -WebSession $client.sid -Body $params ).Content | ConvertFrom-Json | Select-Object comment -ExpandProperty comment
            }
            catch {
                pause
            }
            Start-Sleep -Milliseconds 10
            $_.topic_id = ( Select-String "\d*$" -InputObject $comment ).Matches.Value
        }
    }
}

function Initialize-Forum () {
    if ( !$forum ) {
        Write-Host 'Не обнаружены данные для подключения к форуму. Проверьте настройки.' -ForegroundColor Red
        Exit
    }
    Write-Host 'Авторизуемся на форуме.'

    $login_url = 'https://rutracker.org/forum/login.php'
    # $login_url = 'https://rutracker.net/forum/login.php'
    $headers = @{ 'User-Agent' = 'Mozilla/5.0' }
    $payload = @{ 'login_username' = $forum.login; 'login_password' = $forum.password; 'login' = '%E2%F5%EE%E4' }
    $i = 1

    while ($true) {
        try {
            if ( [bool]$forum.ProxyURL ) {
                if ( $proxycred ) {
                    Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck -Proxy $forum.ProxyURL -ProxyCredential $proxyCred | Out-Null
                }
                else {
                    Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck -Proxy $forum.ProxyURL | Out-Null
                }
            }
            else { Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck | Out-Null }
            break
        }
        catch {
            Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan
        }
    }
    if ( $sid.Cookies.Count -eq 0 ) {
        Write-Host '[forum] Не удалось авторизоваться на форуме.'
        Exit
    }
    $forum.sid = $sid
    Write-Host ( 'Успешно.' )
}

function Get-ForumTorrentFile ( [int]$Id, $save_path = $null) {
    if ( !$forum.sid ) { Initialize-Forum }
    $forum_url = 'https://rutracker.org/forum/dl.php?t=' + $Id
    if ( $null -eq $save_path ) { $Path = $PSScriptRoot + '\' + $Id + '.torrent' } else { $path = $save_path + '\' + $Id + '.torrent' }
    $i = 1
    while ( $true ) {
        try { 
            if ( [bool]$forum.ProxyURL ) {
                if ( $proxycred ) {
                    Invoke-WebRequest -uri $forum_url -WebSession $forum.sid -OutFile $Path -Proxy $forum.ProxyURL -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck -ProxyCredential $proxyCred
                }
                else {
                    Invoke-WebRequest -uri $forum_url -WebSession $forum.sid -OutFile $Path -Proxy $forum.ProxyURL -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck
                }
                break
            }
            else {
                Invoke-WebRequest -uri $forum_url -WebSession $forum.sid -OutFile $Path -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck
                break
            }
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    if ( $nul -eq $save_path ) { return Get-Item $Path }
}

function Add-ClientTorrent ( $Client, $File, $Path, $Category, $Skip_checking = $false ) {
    $Params = @{
        torrents      = Get-Item $File
        savepath      = $Path
        category      = $Category
        name          = 'torrents'
        root_folder   = 'false'
        paused        = $Paused
        skip_checking = $Skip_checking
    }

    # Добавляем раздачу в клиент.
    $url = $client.ip + ':' + $client.Port + '/api/v2/torrents/add'
    try { Invoke-WebRequest -Method POST -Uri $url -WebSession $client.sid -Form $Params -ContentType 'application/x-bittorrent' | Out-Null }
    catch { exit }
    Remove-Item $File
}

function Get-ForumName( $section ) {
    $i = 1
    while ($true) {
        try {
            if ( [bool]$forum.UseApiProxy ) {
                if ( $proxyCred ) {
                    $ForumName = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/get_forum_data?by=forum_id&val=$section" -Proxy $forum.ProxyURL -ProxyCredential $proxyCred ).content | ConvertFrom-Json -AsHashtable ).result[$section].forum_name
                }
                else {
                    $ForumName = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/get_forum_data?by=forum_id&val=$section" -Proxy $forum.ProxyURL ).content | ConvertFrom-Json -AsHashtable ).result[$section].forum_name
                }
            }
            else {
                $ForumName = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/get_forum_data?by=forum_id&val=$section" ).content | ConvertFrom-Json -AsHashtable ).result[$section].forum_name
            }
            break
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    return $ForumName
}

function Remove-ClientTorrent ( $client, $hash, $deleteFiles ) {
    try {
        if ( $deleteFiles -eq $true ) {
            $text = 'Удаляем из клиента ' + $client.Name + ' раздачу ' + $hash + ' вместе с файлами'
            Write-Host $text
            # if ( $nul -ne $tg_token -and '' -ne $tg_token ) { Send-TGMessage $text $tg_token $tg_chat }
        }
        else {
            $text = 'Удаляем из клиента ' + $client.Name + ' раздачу ' + $hash + ' без удаления файлов'
            Write-Host $text
            # if ( $nul -ne $tg_token -and '' -ne $tg_token ) { Send-TGMessage $text $tg_token $tg_chat }
        }
        $request_delete = @{
            hashes      = $hash
            deleteFiles = $deleteFiles
        }
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/delete' ) -WebSession $client.sid -Body $request_delete -Method POST | Out-Null
    }
    catch {
        Write-Host ( '[delete] Почему-то не получилось удалить раздачу {0}.' -f $torrent_id )
    }
}

function Send-Report ( $wait = $false ) {
    $lock_file = "$PSScriptRoot\in_progress.lck"
    $in_progress = Test-Path -Path $lock_file
    if ( !$in_progress ) {
        if ( $wait ) {
            Write-Host 'Подождём 5 минут, вдруг быстро скачается.'
            Start-Sleep -Seconds 300
        }
        New-Item -Path "$PSScriptRoot\in_progress.lck" | Out-Null
        try {
            Write-Host 'Обновляем БД'
            . $php_path "$tlo_path\php\actions\update_info.php" | Out-Null
            Write-Host 'Шлём отчёт'
            . $php_path "$tlo_path\php\actions\send_reports.php" | Out-Null
        }
        finally {
            Remove-Item $lock_file -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Host "Обнаружен файл блокировки $lock_file. Вероятно, запущен параллельный процесс. Если это не так, удалите файл" -ForegroundColor Red
    }
}

function Get-SectionTorrents ( $forum, $section, $max_seeds) {
    if ( $max_seeds -eq -1 ) { $seed_limit = 999 } else { $seed_limit = $max_seeds }
    $i = 1
    Write-Host ('Получаем с трекера раздачи раздела ' + $section + '... ' ) -NoNewline
    while ( $true) {
        try {
            if ( [bool]$forum.ProxyURL -and $forum.UseApiProxy -eq 1 ) {
                if ( $proxyCred ) {
                $tmp_torrents = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/static/pvc/f/$section" -Proxy $forum.ProxyURL -ProxyCredential $proxyCred ).Content | ConvertFrom-Json -AsHashtable ).result
                }
                else {
                    $tmp_torrents = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/static/pvc/f/$section" -Proxy $forum.ProxyURL ).Content | ConvertFrom-Json -AsHashtable ).result
                }
            }
            else {
                $tmp_torrents = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/static/pvc/f/$section" ).Content | ConvertFrom-Json -AsHashtable ).result
            }
            break
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    Write-Host ( 'Получено раздач: ' + $tmp_torrents.count )
    if ( $max_seeds -gt -1 ) {
        $tmp_torrents_2 = @{}
        $tmp_torrents.keys | Where-Object { $tmp_torrents[$_][1] -le $seed_limit } | ForEach-Object { $tmp_torrents_2[$_] = $tmp_torrents[$_] }
        $tmp_torrents = $tmp_torrents_2
        Remove-Variable -Name tmp_torrents_2
        Write-Host ( 'Раздач с кол-вом сидов не более ' + $seed_limit + ': ' + $tmp_torrents.count )
    }
    if ( !$tmp_torrents ) {
        Write-Host 'Не получилось' -ForegroundColor Red
        exit 
    }
    return $tmp_torrents
}

function Set-Preferences {
    $tlo_path = 'C:\OpenServer\domains\webtlo.local'
    # $php_path = 'C:\OpenServer\modules\php\PHP_8.1\php.exe'
    $max_seeds = -1
    $get_hidden = 'N'
    $get_blacklist = 'N'
    $get_news = 'N'
    Clear-Host
    Write-Host 'Не обнаружено настроек' -ForegroundColor Red
    Write-Host 'Вот и создадим их.' -ForegroundColor Green
    Write-Host 'Для получения информации о клиентах и хранимых разделах мне нужен путь к каталогу Web-TLO'
    Write-Host 'Если путь верный, можно просто нажать Enter. Если нет - укажите верный'
    while ( $true ) {
        If ( ( $prompt = Read-Host -Prompt "Путь к папке Web-TLO [$tlo_path]" ) -ne '' ) {
            $tlo_path = $prompt -replace ( '\s+$', '') -replace '\\$', '' 
        }
        $ini_path = $tlo_path + '\data\config.ini'
        If ( Test-Path $ini_path ) {
            break
        }
        Write-Host 'Не нахожу такого файла, проверьте ввод' -ForegroundColor Red
    }

    if ( ( $prompt = Read-host -Prompt "Максимальное кол-во сидов для скачивания раздачи [$max_seeds]" ) -ne '' ) {
        $max_seeds = [int]$prompt
    }

    while ( $true ) {
        If ( ( $prompt = Read-host -Prompt "Скачивать раздачи из скрытых разделов Web-TLO? (Y/N) [$get_hidden]" ) -ne '' ) {
            $get_hidden = $prompt.ToUpper() 
        }
        If ( $get_hidden -match '^[Y|N]$' ) { break }
        Write-Host 'Я ничего не понял, проверьте ввод' -ForegroundColor Red
    }

    while ( $true ) {
        If ( ( $prompt = Read-host -Prompt "Скачивать раздачи из чёрного списка Web-TLO? (Y/N) [$get_blacklist]" ) -ne '' ) {
            $get_blacklist = $prompt.ToUpper() 
        }
        If ( $get_blacklist -match '^[Y|N]$' ) { break }
        Write-Host 'Я ничего не понял, проверьте ввод' -ForegroundColor Red
    }

    while ( $true ) {
        If ( ( $prompt = Read-host -Prompt "Скачивать новые раздачи? (Y/N) [$get_news]" ) -ne '' ) {
            $get_news = $prompt.ToUpper() 
        }
        If ( $get_news -match '^[Y|N]$' ) { break }
        Write-Host 'Я ничего не понял, проверьте ввод' -ForegroundColor Red
    }

    if ( ( $prompt = Read-host -Prompt "Токен бота Telegram, если нужна отправка событий в Telegram. Если не нужно, оставить пустым" ) -ne '' ) {
        $tg_token = $prompt
        if ( ( $prompt = Read-host -Prompt "Номер чата для отправки сообщений Telegram" ) -ne '' ) {
            $tg_chat = $prompt
        }
    }
    
    Write-Output ( '$tlo_path = ' + "'$tlo_path'" + "`r`n" + '$max_seeds = ' + $max_seeds + "`r`n" + '$get_hidden = ' + "'" + $get_hidden + "'`r`n" + '$get_blacklist = ' + "'" + $get_blacklist + "'`r`n" + '$get_news = ' + "'" + $get_news + "'`r`n" + '$tg_token = ' + "'" + $tg_token + "'`r`n" + '$tg_chat = ' + "'" + $tg_chat + "'") | Out-File "$PSScriptRoot\_settings.ps1"
}

function Get-Separator {
    if ( $PSVersionTable.OS.ToLower().contains('windows')) { $separator = '\' } else { $separator = '/' }
    return $separator
}

function  Open-Database {
    $sepa = Get-Separator
    $database_path = $tlo_path + $sepa + 'data' + $sepa + 'webtlo.db'
    Write-Host 'Путь к базе данных:' $database_path
    $conn = New-SqliteConnection -DataSource $database_path
    return $conn
}

function Get-Blacklist {
    Write-Host 'Запрашиваем чёрный список из БД Web-TLO'
    $blacklist = @{}
    # $sepa = Get-Separator
    $conn = Open-Database
    $query = 'SELECT info_hash FROM TopicsExcluded'
    Invoke-SqliteQuery -Query $query -SQLiteConnection $conn | ForEach-Object { $blacklist[$_.info_hash] = 1 }
    $conn.Close()
    return $blacklist
}

function ConvertFrom-Empty( $from, $to ) {
    if ( $from -eq '') { return $to }
    else { return $from }
}

function Start-Torrents( $hashes, $client) {
    $Params = @{ hashes = ( $hashes -join '|' ) }
    $url = $client.ip + ':' + $client.Port + '/api/v2/torrents/resume'
    Invoke-WebRequest -Method POST -Uri $url -WebSession $client.sid -Form $Params -ContentType 'application/x-bittorrent' | Out-Null
}

function Stop-Torrents( $hashes, $client) {
    $Params = @{ hashes = ( $hashes -join '|' ) }
    $url = $client.ip + ':' + $client.Port + '/api/v2/torrents/pause'
    Invoke-WebRequest -Method POST -Uri $url -WebSession $client.sid -Form $Params -ContentType 'application/x-bittorrent' | Out-Null
}

function Select-Client {
    $clients.keys | ForEach-Object {
        Write-Host ( $_ + '. ' + $clients[$_].Name )
    }
    $ok2 = $false
    while ( !$ok2 ) {
        $choice = Read-Host Выберите клиент
        if (  $clients[ $choice ] ) { $ok2 = $true }
    }
    return $clients[$choice]
}

Function Set-ForumDetails ( $forum ) {
    If ( ( [bool]$ini_data.proxy.activate_forum -or [bool]$ini_data.proxy.activate_api ) -and ( -not $forceNoProxy ) ) {
        Write-Host ( 'Используем ' + $ini_data.proxy.type.Replace('socks5h', 'socks5') + ' прокси ' + $ini_data.proxy.hostname + ':' + $ini_data.proxy.port )
        $forum.UseApiProxy = $ini_data.proxy.activate_api
        $forum.ProxyIP = $ini_data.proxy.hostname
        $forum.ProxyPort = $ini_data.proxy.port
        $forum.ProxyURL = 'socks5://' + $ini_data.proxy.hostname + ':' + $ini_data.proxy.port
        $forum.ProxyLogin = $ini_data.proxy.login
        $forum.ProxyPassword = $ini_data.proxy.password
    }
    $forum.UseProxy = $ini_data.proxy.activate_forum
    $forum.Login = $ini_data.'torrent-tracker'.login
    $forum.Password = $ini_data.'torrent-tracker'.password
}

function Select-Path ( $direction ) {
    # $defaultTo = 'Хранимые'
    if ( $direction -eq 'from' ) {
        $default = 'Хранимое'
        $str = "Выберите исходный кусок пути [$default]"
    }
    else {
        $default = 'Хранимые'
        $str = "Выберите целевой кусок пути [$default]"
    } 
    $choice = Read-Host $str
    $result = ( $default, $choice )[[bool]$choice]
    return $result
}

function Get-String ( $obligatory, $prompt ) { 
    while ( $true ) {
        $choice = ( Read-Host $prompt )
        if ( $nul -ne $choice -and $choice -ne '') { break }
        elseif ( !$obligatory ) { break }
    }
    if ( $choice ) { return $choice } else { return '' }
}

function Get-Disk ( $obligatory, $prompt ) { 
    while ( $true ) {
        $disk = Get-String $obligatory $prompt
        if ( ( $disk -and $disk.Length -eq 1 ) -or !$obligatory ) { 
            $disk = $disk.ToUpper()
            break 
        } 
    }
    return $disk
}


function  Set-Location ( $client, $torrent, $new_path, $verbose = $false) {
    if ( $verbose ) { Write-Host ( 'Перемещаем ' + $torrent.name ) }
    $data = @{
        hashes   = $torrent.hash
        location = $new_path
    }
    try {
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/setLocation' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
    catch {
        $client.sid = $null
        Initialize-Client $client
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/setLocation' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
}

function Convert-Path ( $client, $path ) {
    if ( $env:COMPUTERNAME -ne $client_hosts[$client.Name] ) {
        $path = '\\' + $client_hosts[$client.Name] + '\' + $path.replace( ':', '')
    }
    return $path
}
