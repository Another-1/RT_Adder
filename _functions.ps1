function Send-TGMessage ( $message, $token, $chat_id ) {
    $payload = @{
        "chat_id"                  = $chat_id
        "parse_mode"               = 'html'
        "disable_web_page_preview" = $true
        "text"                     = $message
    }
    
    Invoke-WebRequest -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $token) -Method Post  -ContentType "application/json;charset=utf-8" -Body (ConvertTo-Json -Compress -InputObject $payload) | Out-Null
}

function Send-TGReport ( $refreshed, $added, $token, $chat_id ) {
    $message = ''
    $first = $true
    foreach ( $key in $refreshed.Keys ) {
        if ( !$first ) { $message += "`n`n"}
        $first = $false
        $message += "Обновлены в клиенте $key :"
        $refreshed[$key] | ForEach-Object { $message += "`n$_"}
    }

    if ( $message -ne '' ) { $message += "`n`n" }
    $first = $true
    foreach ( $key in $added.Keys ) {
        if ( !$first ) { $message += "`n`n"}
        $first = $false
        $message += "Добавлены в клиент $key :"
        $added[$key] | ForEach-Object { $message += "`n$_"}
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
                Select-Object name, hash, save_path, content_path, category, @{ N = 'topic_id'; E = { $nul } }, @{ N = 'client_key'; E = { $client_key } } | Where-Object { $_.save_path -match ('^' + $dsk ) }
        }
        catch { exit }
        return $torrents_list
    }
}

function Get-TopicIDs ( $client, $torrent_list ) {
    Write-Host 'Ищем ID'
    $torrent_list | ForEach-Object { $_.topic_id = $tracker_torrents[$_.hash.toUpper()].id }
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
                Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck -Proxy $forum.ProxyURL | Out-Null
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

function Get-ForumTorrentFile ( [int]$Id ) {
    if ( !$forum.sid ) { Initialize-Forum }
    $forum_url = 'https://rutracker.org/forum/dl.php?t=' + $Id
    $Path = $PSScriptRoot + '\' + $Id + '_' + $Type + '.torrent'
    $i = 1
    while ( $true ) {
        try { 
            if ( [bool]$forum.ProxyURL ) {
                Invoke-WebRequest -uri $forum_url -WebSession $forum.sid -OutFile $Path -Proxy $forum.ProxyURL -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck
                break
            }
            else {
                Invoke-WebRequest -uri $forum_url -WebSession $forum.sid -OutFile $Path -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck
                break
            }
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    return Get-Item $Path
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
                $ForumName = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/get_forum_data?by=forum_id&val=$section" -Proxy $forum.ProxyURL ).content | ConvertFrom-Json -AsHashtable ).result[$section].forum_name
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
            if ( $nul -ne $tg_token -and '' -ne $tg_token ) { Send-TGMessage $text $tg_token $tg_chat }
        }
        else {
            $text = 'Удаляем из клиента ' + $client.Name + ' раздачу ' + $hash + ' без удаления файлов'
            Write-Host $text
            if ( $nul -ne $tg_token -and '' -ne $tg_token ) { Send-TGMessage $text $tg_token $tg_chat }
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

function Send-Report {
    $lock_file = "$PSScriptRoot\in_progress.lck"
    $in_progress = Test-Path -Path $lock_file
    if ( !$in_progress ) {
        New-Item -Path "$PSScriptRoot\in_progress.lck" | Out-Null
        Write-Host 'Обновляем БД'
        . $php_path "$tlo_path\cron\update.php"
        Write-Host 'Шлём отчёт'
        . $php_path "$tlo_path\cron\reports.php"
        Remove-Item $lock_file
    }
    else {
        Write-Host "Обнаружен файл блокировки $lock_file. Вероятно, запущен параллельный процесс. Если это не так, удалите файл" -ForegroundColor Red
    }
}

function Get-SectionTorrents ( $forum, $section, $max_seeds) {
    if ( $max_seeds -eq -1 ) { $seed_limit = 999 } else { $seed_limit = $max_seeds }
    $i = 1
    while ( $true) {
        try {
            if ( [bool]$forum.ProxyURL ) {
                $tmp_torrents = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/static/pvc/f/$section" -Proxy $forum.ProxyURL ).Content | ConvertFrom-Json -AsHashtable ).result
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
    Write-Host
    return $tmp_torrents
}

function Set-Preferences {
    $tlo_path = 'C:\OpenServer\domains\webtlo.local'
    # $php_path = 'C:\OpenServer\modules\php\PHP_8.1\php.exe'
    $max_seeds = -1
    $get_hidden = 'N'
    $get_blacklist = 'N'
    Clear-Host
    Write-Host 'Не обнаружено настроек' -ForegroundColor Red
    Write-Host 'Вот и создадим их.' -ForegroundColor Green
    Write-Host 'Для получения информации о коиентах и хранимых разделах мне нужен путь к каталогу Web-TLO'
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

    if ( ( $prompt = Read-host -Prompt "Токен бота Telegram, если нужна отправка событий в Telegram. Если не нужно, оставить пустым" ) -ne '' ) {
        $tg_token = $prompt
        if ( ( $prompt = Read-host -Prompt "Номер чата для отправки сообщений Telegram" ) -ne '' ) {
            $tg_chat = $prompt
        }
    }
    
    Write-Output ( '$tlo_path = ' + "'$tlo_path'" + "`r`n" + '$max_seeds = ' + $max_seeds + "`r`n" + '$get_hidden = ' + "'" + $get_hidden + "'`r`n" + '$get_blacklist = ' + "'" + $get_blacklist + "'`r`n" + '$tg_token = ' + "'" + $tg_token + "'`r`n" + '$tg_chat = ' + "'" + $tg_chat + "'") | Out-File "$PSScriptRoot\_settings.ps1"
}

function Get-Separator {
    if ( $PSVersionTable.OS.ToLower().contains('windows')) { $separator = '\' } else { $separator = '/' }
    return $separator
}

function Get-Blacklist {
    Write-Host 'Запрашиваем чёрный список из БД Web-TLO'
    $blacklist = @{}
    $sepa = Get-Separator
    $database_path = $tlo_path + $sepa + 'data' + $sepa + 'webtlo.db'
    $conn = New-SqliteConnection -DataSource $database_path
    $query = 'SELECT info_hash FROM TopicsExcluded'
    Invoke-SqliteQuery -Query $query -SQLiteConnection $conn | ForEach-Object { $blacklist[$_.info_hash] = 1 }
    $conn.Close()
    return $blacklist
}