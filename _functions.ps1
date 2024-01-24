function to_kmg ($bytes, [int]$precision = 0) {
    foreach ($i in ("Bytes", "KB", "MB", "GB", "TB")) {
        if (($bytes -lt 1024) -or ($i -eq "TB")) {
            $bytes = ($bytes).tostring("F0" + "$precision")
            return $bytes + " $i"
        }
        else {
            $bytes /= 1KB
        }
    }
}

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
    if ( $refreshed.Count -gt 0 -or $added.Count -gt 0 -or $obsolete.Count -gt 0 ) {
        if ( $brief_reports -ne 'Y') {
            # полная сводка в ТГ
            $message = ''
            $first = $true
            foreach ( $client in $refreshed.Keys ) {
                if ( !$first ) { $message += "`n" }
                $first = $false
                $message += "Обновлены в клиенте <b>$client</b>`n"
                $refreshed[$client].keys | Sort-Object | ForEach-Object {
                    # $message += "<i>Раздел $_</i>`n"
                    $refreshed[$client][$_] | ForEach-Object { $message += "$_`n" }
                }
            }

            if ( $message -ne '' ) { $message += "`n" }

            $first = $true
            foreach ( $client in $added.Keys ) {
                if ( !$first ) { $message += "`n" }
                $first = $false
                $message += "Добавлены в клиент <b>$client</b>`n"
                $added[$client].keys | Sort-Object | ForEach-Object {
                    # $message += "<i>Раздел $_</i>`n"
                    $added[$client][$_] | ForEach-Object { $message += "$_`n" }
                }
            }

            if ( $message -ne '' ) { $message += "`n" }
            $first = $true
            foreach ( $client in $obsolete.Keys ) {
                if ( !$first ) { $message += "`n" }
                $first = $false
                $message += "Лишние в клиенте $client :`n"
                $obsolete[$client] | ForEach-Object { $message += "$_`n" }
            }
        }
        else {
            # краткая сводка в ТГ
            $message = ''
            $keys = (  $refrehed.keys + $added.keys + $obsolete.Keys ) | Sort-Object -Unique
            foreach ( $client in $keys ) {
                if ( $message -ne '' ) { $message += "`n" }
                $message += "<u>Клиент <b>$client</b></u>`n"
                if ( $refreshed -and $refreshed[$client] ) {
                    # $first = $true
                    $refreshed[$client].keys | Sort-Object | ForEach-Object {
                        if ( $message -ne '' ) { $message += "`n" }
                        # $message += "<i>Раздел $_</i>`n"
                        $message += ( "Обновлено: " + $refreshed[$client][$_].count + "`n")
                    }
                }
                # if ( !$first ) { $message += "`n" }
                if ( $added -and $added[$client] ) {
                    # $first = $true
                    $added[$client].keys | Sort-Object | ForEach-Object {
                        # if ( $message -ne '' ) { $message += "`n" }
                        # $message += "<i>Раздел $_</i>`n"
                        $message += ( "Добавлено: " + $added[$client][$_].count + "`n")
                    }
                }
                # if ( !$first ) { $message += "`n" }
                if ( $obsolete -and $obsolete[$client] ) {
                    $message += ( "Лишних: " + $obsolete[$client].count + "`n" )
                }
            }
        }
        Send-TGMessage $message $token $chat_id
    }
    else {
        $message = 'Ничего делать не понадобилось'
        Send-TGMessage $message $token $chat_id
    }
}

function Initialize-Client ($client, $verbose = $true, $force = $false ) {
    if ( !$client.sid -or $force -eq $true ) {
        $logindata = @{
            username = $client.login
            password = $client.password
        }
        $loginheader = @{ Referer = 'http://' + $client.IP + ':' + $client.Port }
        try {
            if ( $verbose -eq $true ) { Write-Log ( 'Авторизуемся в клиенте ' + $client.Name ) }
            $url = $client.IP + ':' + $client.Port + '/api/v2/auth/login'
            $result = Invoke-WebRequest -Method POST -Uri $url -Headers $loginheader -Body $logindata -SessionVariable sid
            if ( $result.StatusCode -ne 200 ) {
                throw 'You are banned.'
            }
            if ( $result.Content.ToUpper() -ne 'OK.') {
                throw $result.Content
            }
            $client.sid = $sid
        }
        catch {
            if ( !$Retry ) {
                Write-Host ( '[client] Не удалось авторизоваться в клиенте, прерываем. Ошибка: {0}.' -f $Error[0] ) -ForegroundColor Red
                Send-TGMessage ( 'Нет связи с клиентом ' + $client.Name + '. Процесс остановлен.' ) $tg_token $tg_chat
                Exit
            }
        }
    }
}

function  Get-Torrents ( $client, $disk = '', $Completed = $true, $hash = $null, $client_key, $verbose = $true) {
    $Params = @{}
    if ( $Completed ) {
        $Params.filter = 'completed'
    }
    if ( $nul -ne $hash ) {
        $Params.hashes = $hash
        if ( $verbose -eq $true ) { Write-Log ( 'Получаем инфо о раздаче из клиента ' + $client.Name ) }
    }
    elseif ( $verbose -eq $true ) { Write-Log ( 'Получаем список раздач от клиента ' + $client.Name ) }
    if ( $disk -ne '') { $dsk = $disk + ':\\' } else { $dsk = '' }
    $i = 0
    while ( $true ) {
        try {
            $torrents_list = ( Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/info' ) -WebSession $client.sid -Body $params -TimeoutSec 30 ).Content | ConvertFrom-Json | `
                Select-Object name, hash, save_path, content_path, category, state, uploaded, @{ N = 'topic_id'; E = { $nul } }, @{ N = 'client_key'; E = { $client_key } }, infohash_v1, size, completion_on, progress, tracker | `
                Where-Object { $_.save_path -match ('^' + $dsk ) }
        }
        catch {
            Initialize-Client $client $false $true
            $torrents_list = ( Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/info' ) -WebSession $client.sid -Body $params -TimeoutSec 30 ).Content | ConvertFrom-Json | `
                Select-Object name, hash, save_path, content_path, category, state, uploaded, @{ N = 'topic_id'; E = { $nul } }, @{ N = 'client_key'; E = { $client_key } }, infohash_v1, size, completion_on, progress, tracker | `
                Where-Object { $_.save_path -match ('^' + $dsk ) }
        }
        if ( $torrents_list -or $i -gt 3 ) { break }
    }
    if ( !$torrents_list ) { 
        Send-TGMessage ( 'Нет связи с клиентом ' + $client.Name + '. Adder остановлен.' ) $tg_token $tg_chat
     }
    return $torrents_list

}

function  Get-TorrentFiles ( $client, $hash = $null, $verbose = $true) {
    $Params = @{}
        $Params.hash = $hash
        if ( $verbose -eq $true ) { Write-Log ( 'Получаем инфо о содержимом раздачи ' ) }
    while ( $true ) {
        try {
            $torrent_files = ( Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/files' ) -WebSession $client.sid -Body $params -TimeoutSec 30 ).Content | ConvertFrom-Json | `
                Select-Object name, hash, save_path, content_path, category, state, uploaded, @{ N = 'topic_id'; E = { $nul } }, @{ N = 'client_key'; E = { $client_key } }, infohash_v1, size, completion_on, progress | `
                Where-Object { $_.save_path -match ('^' + $dsk ) }
        }
        catch {
            Initialize-Client $client $false $true
            $torrent_files = ( Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/files' ) -WebSession $client.sid -Body $params -TimeoutSec 30 ).Content | ConvertFrom-Json | `
                Select-Object name, hash, save_path, content_path, category, state, uploaded, @{ N = 'topic_id'; E = { $nul } }, @{ N = 'client_key'; E = { $client_key } }, infohash_v1, size, completion_on, progress | `
                Where-Object { $_.save_path -match ('^' + $dsk ) }
        }
        if ( !$torrents_files ) { $torrents_files = @() }
        return $torrent_files
    }
}

function Get-TopicIDs ( $client, $torrent_list ) {
    Write-Host 'Ищем ID'
    if ( $torrent_list.count -gt 0 ) {
        $torrent_list | ForEach-Object {
            if ( $nul -ne $tracker_torrents ) { $_.topic_id = $tracker_torrents[$_.hash.toUpper()].id }
            if ( $nul -eq $_.topic_id ) {
                $Params = @{ hash = $_.hash }
                try {
                    $comment = ( Invoke-WebRequest -uri ( $client.IP + ':' + $client.Port + '/api/v2/torrents/properties' ) -WebSession $client.sid -Body $params ).Content | ConvertFrom-Json | Select-Object comment -ExpandProperty comment
                    Start-Sleep -Milliseconds 10
                }
                catch {
                    pause
                }
                $_.topic_id = ( Select-String "\d*$" -InputObject $comment ).Matches.Value
            }
        }
    }
}

function Initialize-Forum () {
    if ( !$forum ) {
        Write-Host 'Не обнаружены данные для подключения к форуму. Проверьте настройки.' -ForegroundColor Red
        Exit
    }
    Write-Host 'Авторизуемся на форуме.'

    $login_url = 'https://' + $forum.url + '/forum/login.php'
    $headers = @{ 'User-Agent' = 'Mozilla/5.0' }
    $payload = @{ 'login_username' = $forum.login; 'login_password' = $forum.password; 'login' = '%E2%F5%EE%E4' }
    $i = 1

    while ($true) {
        try {
            if ( [bool]$forum.ProxyURL ) {
                if ( $proxycred ) {
                    Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -SkipHttpErrorCheck -Proxy $forum.ProxyURL -ProxyCredential $proxyCred | Out-Null
                }
                else {
                    Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -SkipHttpErrorCheck -Proxy $forum.ProxyURL | Out-Null
                }
            }
            else { Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -SkipHttpErrorCheck | Out-Null }
            break
        }
        catch {
            Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan
            If ( $i -gt 20 ) { break }
        }
    }
    if ( $sid.Cookies.Count -eq 0 ) {
        Write-Host 'Не удалось авторизоваться на форуме.' -ForegroundColor Red
        Exit
    }
    $forum.sid = $sid
    Write-Host ( 'Успешно.' )
}

function Get-ForumTorrentFile ( [int]$Id, $save_path = $null) {
    if ( !$forum.sid ) { Initialize-Forum }
    $get_url = 'https://' + $forum.url + '/forum/dl.php?t=' + $Id
    if ( $null -eq $save_path ) { $Path = $PSScriptRoot + '\' + $Id + '.torrent' } else { $path = $save_path + '\' + $Id + '.torrent' }
    $i = 1
    while ( $i -le 30 ) {
        try { 
            if ( [bool]$forum.ProxyURL ) {
                if ( $proxycred ) {
                    Invoke-WebRequest -uri $get_url -WebSession $forum.sid -OutFile $Path -Proxy $forum.ProxyURL -MaximumRedirection 999 -SkipHttpErrorCheck -ProxyCredential $proxyCred
                }
                else {
                    Invoke-WebRequest -uri $get_url -WebSession $forum.sid -OutFile $Path -Proxy $forum.ProxyURL -MaximumRedirection 999 -SkipHttpErrorCheck
                }
                break
            }
            else {
                Invoke-WebRequest -uri $get_url -WebSession $forum.sid -OutFile $Path -MaximumRedirection 999 -SkipHttpErrorCheck
                break
            }
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    if ( $nul -eq $save_path ) { return Get-Item $Path }
}

function Start-Rehash ( $client, $hash ) {
    $Params = @{ hashes = $hash }
    $url = $client.ip + ':' + $client.Port + '/api/v2/torrents/recheck'
    Invoke-WebRequest -Method POST -Uri $url -WebSession $client.sid -Form $Params -ContentType 'application/x-bittorrent' | Out-Null
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
    $added_ok = $false
    $i = 1
    while ( $added_ok -eq $false) {
        try {
            Invoke-WebRequest -Method POST -Uri $url -WebSession $client.sid -Form $Params -ContentType 'application/x-bittorrent' | Out-Null
            $added_ok = $true
        }
        catch {
            $i++
            Initialize-Client $client $false $true
            Start-Sleep -Seconds 1
            Write-Host "Попытка № $i"
        }
    }
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
        }
        else {
            $text = 'Удаляем из клиента ' + $client.Name + ' раздачу ' + $hash + ' без удаления файлов'
            Write-Host $text
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

function Send-Report () {
    Write-Host 'Шлём отчёт'
    . $php_path "$tlo_path\cron\reports.php"
}

function Update-Stats ( $wait = $false, $check = $false, $send_rep = $false ) {
    $lock_file = "$PSScriptRoot\in_progress.lck"
    $in_progress = Test-Path -Path $lock_file
    if ( !$in_progress ) {
        If ( ( ( Get-Date($MoscowTime) -UFormat %H ).ToInt16( $nul ) + 2 ) % 2 -eq 0 -or ( $check -eq $false ) ) {
            if ( $wait ) {
                Write-Host 'Подождём 5 минут, вдруг быстро скачается.'
                Start-Sleep -Seconds 300
            }
            New-Item -Path "$PSScriptRoot\in_progress.lck" | Out-Null
            try {
                Write-Host 'Обновляем БД'
                . $php_path "$tlo_path\cron\update.php"
                Write-Host 'Обновляем списки других хранителей'
                . $php_path "$tlo_path\cron\keepers.php"
                if ( $true -eq $send_rep ) {
                    Send-Report
                }
            }
            finally {
                Remove-Item $lock_file -ErrorAction SilentlyContinue
            }
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

function Get-UserTorrents ( $forum ) {
    $i = 1
    Write-Host ('Получаем с трекера раздачи пользователя ' + $forum.UserID + '... ' )
    while ( $true) {
        try {
            if ( [bool]$forum.ProxyURL -and $forum.UseApiProxy -eq 1 ) {
                if ( $proxyCred ) {
                    $tmp_torrents = ( ( Invoke-WebRequest -Uri ( 'https://api.rutracker.cc/v1/get_user_torrents?by=user_id&val=' + $forum.UserID ) -Proxy $forum.ProxyURL -ProxyCredential $proxyCred ).Content | ConvertFrom-Json -AsHashtable ).result[$forum.UserID]
                }
                else {
                    $tmp_torrents = ( ( Invoke-WebRequest -Uri ( 'https://api.rutracker.cc/v1/get_user_torrents?by=user_id&val=' + $forum.UserID ) -Proxy $forum.ProxyURL ).Content | ConvertFrom-Json -AsHashtable ).result[$forum.UserID]
                }
            }
            else {
                $tmp_torrents = ( ( Invoke-WebRequest -Uri ( 'https://api.rutracker.cc/v1/get_user_torrents?by=user_id&val=' + $forum.UserID ) ).Content | ConvertFrom-Json -AsHashtable ).result[$forum.UserID]
            }
            break
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    Write-Host ( 'Получено раздач: ' + $tmp_torrents.count )
    if ( !$tmp_torrents ) {
        Write-Host 'Не получилось' -ForegroundColor Red
        exit 
    }
    return $tmp_torrents
}

function Set-Preferences ( $tlo_path, $max_seeds, $get_hidden, $get_blacklist, $get_news, $tg_token, $tg_chat ) {
    $tlo_path = 'C:\OpenServer\domains\webtlo.local'
    $max_seeds = -1
    $get_shown = 'Y'
    $get_lows = 'N'
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
        If ( ( $prompt = Read-host -Prompt "Скачивать раздачи из НЕскрытых разделов Web-TLO? (Y/N) [$get_shown]" ) -ne '' ) {
            $get_shown = $prompt.ToUpper() 
        }
        If ( $get_shown -match '^[Y|N]$' ) { break }
        Write-Host 'Я ничего не понял, проверьте ввод' -ForegroundColor Red
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

    while ( $true ) {
        If ( ( $prompt = Read-host -Prompt "Скачивать раздачи c низким приоритетом? (Y/N) [$get_lows]" ) -ne '' ) {
            $get_lows = $prompt.ToUpper() 
        }
        If ( $get_lows -match '^[Y|N]$' ) { break }
        Write-Host 'Я ничего не понял, проверьте ввод' -ForegroundColor Red
    }

    if ( ( $prompt = Read-host -Prompt "Токен бота Telegram, если нужна отправка событий в Telegram. Если не нужно, оставить пустым" ) -ne '' ) {
        $tg_token = $prompt
        if ( ( $prompt = Read-host -Prompt "Номер чата для отправки сообщений Telegram" ) -ne '' ) {
            $tg_chat = $prompt
        }
    }
    
    Write-Output ( '$tlo_path = ' + "'$tlo_path'" + "`r`n" + '$max_seeds = ' + $max_seeds + "`r`n" + '$get_shown = ' + "'" + $get_shown + "'`r`n" + '$get_hidden = ' + "'" + $get_hidden + "'`r`n" + '$get_blacklist = ' + "'" + $get_blacklist + "'`r`n" + '$get_news = ' + "'" + $get_news + "'`r`n" + '$get_lows = ' + "'" + $get_lows + "'`r`n" + '$tg_token = ' + "'" + $tg_token + "'`r`n" + '$tg_chat = ' + "'" + $tg_chat + "'") | Out-File "$PSScriptRoot\_settings.ps1"
    Write-Host 'Настройка закончена, запустите меня ещё раз.' -ForegroundColor Green
    Exit
}

function Get-Separator {
    if ( $PSVersionTable.OS.ToLower().contains('windows')) { $separator = '\' } else { $separator = '/' }
    return $separator
}

function  Open-Database( $db_path, $verbose = $true ) {
    if ( $verbose ) { Write-Log ( 'Путь к базе данных: ' + $db_path ) }
    $conn = New-SqliteConnection -DataSource $db_path
    return $conn
}

function  Open-TLODatabase( $verbose = $true ) {
    $sepa = Get-Separator
    $database_path = $tlo_path + $sepa + 'data' + $sepa + 'webtlo.db'
    $conn = Open-Database $database_path $verbose
    return $conn
}

function Get-Blacklist( $verbose = $true ) {
    Write-Host 'Запрашиваем чёрный список из БД Web-TLO'
    $blacklist = @{}
    # $sepa = Get-Separator
    $conn = Open-TLODatabase $verbose
    $query = 'SELECT info_hash FROM TopicsExcluded'
    Invoke-SqliteQuery -Query $query -SQLiteConnection $conn -ErrorAction SilentlyContinue | ForEach-Object { $blacklist[$_.info_hash] = 1 }
    $conn.Close()
    return $blacklist
}

function Get-OldBlacklist( $verbose = $true ) {
    Write-Host 'Запрашиваем старый чёрный список из БД Web-TLO'
    $oldblacklist = @{}
    # $sepa = Get-Separator
    $conn = Open-TLODatabase $verbose
    $query = 'SELECT id FROM Blacklist'
    Invoke-SqliteQuery -Query $query -SQLiteConnection $conn -ErrorAction SilentlyContinue | ForEach-Object { $oldblacklist[$_.id.ToString()] = 1 }
    $conn.Close()
    return $oldblacklist
}

function Get-DBHashesBySecton ( $ss ) {
    Write-Host "Запрашиваем список раздач раздела $ss из БД Web-TLO"
    $conn = Open-TLODatabase
    $query = "SELECT hs FROM Topics WHERE ss = $ss"
    $topics = Invoke-SqliteQuery -Query $query -SQLiteConnection $conn
    $conn.Close()
    return $topics
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
    If ( ( $ini_data.proxy.activate_forum -eq '1' -or $ini_data.proxy.activate_api -eq '1' ) -and ( -not $forceNoProxy ) ) {
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
    $forum.url = $ini_data.'torrent-tracker'.forum_url
    $forum.UserID = $ini_data.'torrent-tracker'.user_id
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
function  Set-SaveLocation ( $client, $torrent, $new_path, $verbose = $false) {
    if ( $verbose ) { Write-Host ( 'Перемещаем ' + $torrent.name + ' в ' + $new_path) }
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

function  Rename-Folder ( $client, $torrent, $old_path, $new_path, $verbose = $false) {
    if ( $verbose ) { Write-Host ( 'Переназываем ' + $torrent.name + ' в ' + $new_path) }
    $data = @{
        hash  = $torrent.hash
        oldPath = $old_path
        newPath = $new_path
    }
    try {
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/renameFolder' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
    catch {
        $client.sid = $null
        Initialize-Client $client
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/renameFolder' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
}

function  Rename-File ( $client, $torrent, $old_path, $new_path, $verbose = $false) {
    if ( $verbose ) { Write-Host ( 'Переназываем ' + $torrent.name + ' в ' + $new_path) }
    $data = @{
        hash  = $torrent.hash
        oldPath = $old_path
        newPath = $new_path
    }
    try {
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/renameFile' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
    catch {
        $client.sid = $null
        Initialize-Client $client
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/renameFile' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
}

function  Set-TorrentCategory ( $client, $torrent, $category, $verbose = $false ) {
    if ( $verbose ) { Write-Host ( 'Категоризируем ' + $torrent.name ) }
    $data = @{
        hashes   = $torrent.hash
        category = $category
    }
    try {
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/setCategory' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
    catch {
        $client.sid = $null
        Initialize-Client $client
        Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/setCategory' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
    }
}

function Convert-Path ( $client, $path ) {
    if ( $env:COMPUTERNAME -ne $client_hosts[$client.Name] ) {
        $path = '\\' + $client_hosts[$client.Name] + '\' + $path.replace( ':', '')
    }
    return $path
}

function Get-Clients {
    $clients = @{}
    Write-Host 'Получаем из TLO данные о клиентах'
    $ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
        $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
        $clients_sort = [ordered]@{}
        $clients.GetEnumerator() | Sort-Object -Property key | ForEach-Object { $clients_sort[$_.key] = $clients[$_.key] }
        $clients = $clients_sort
        Remove-Variable -Name clients_sort -ErrorAction SilentlyContinue
    } 
    return $clients
}

function Set-Comment ( $client, $torrent, $label ) {
    Write-Output ( 'Метим раздачу ' + $torrent.topic_id )
    $tag_url = $client.IP + ':' + $client.Port + '/api/v2/torrents/addTags'
    $tag_body = @{ hashes = $torrent.hash; tags = $label }
    Invoke-WebRequest -Method POST -Uri $tag_url -Headers $loginheader -Body $tag_body -WebSession $client.sid | Out-Null
}

function Get-ClienDetails {
    Write-Host
    Write-Host 'Внимание! Поддерживаются только клиенты qBittorrent!' -ForegroundColor Green
    $client = @{}
    $client.IP = Get-String $true 'IP-адрес веб-интерфейса клиента'
    $client.Port = Get-String $true 'IP-порт веб-интерфейса клиента'
    $client.Login = Get-String $true 'Логин для веб-интерфейса клиента'
    $client.Password = Get-String $true 'Пароль для веб-интерфейса клиента'
    return $client
}

function Get-TorrentTrackers ( $client, $hash ) {
    $params = @{ hash = $hash }
    $trackers = ( Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/trackers' ) -WebSession $client.sid -Body $params ).Content | ConvertFrom-Json
    return $trackers
}

function Get-TorrentInfo ( $id ) {
    $params = @{ 
        by  = 'topic_id'
        val = $id 
    }

    while ( $true ) {
        try {
            $torinfo = ( ( Invoke-WebRequest -uri ( 'https://api.rutracker.cc/v1/get_tor_topic_data' ) -Body $params ).Content | ConvertFrom-Json ).result.$id
            $name = $torinfo.topic_title
            $size = $torinfo.size
            break
        }
        catch {
            Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan
            If ( $i -gt 20 ) { break }
        }
    }
    return [PSCustomObject]@{ 'name' = $name; 'size' = $size }
}

function Edit-Tracker ( $client, $hash, $origUrl, $newUrl ) {
    $params = @{
        hash    = $hash
        origUrl = $origUrl
        newUrl  = $newUrl
    }
    Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/editTracker' ) -WebSession $client.sid -Body $params  -Method Post | out-null
}

Function Get-ClientSetting( $client, $setting ) {
    $url = $client.ip + ':' + $client.Port + '/api/v2/app/preferences'
    $result = ( ( Invoke-WebRequest -Uri $url -WebSession $client.sid ).content | ConvertFrom-Json ).$setting
    return $result
}

Function Set-ClientSetting ( $client, $param, $value ) {
    $url = $client.ip + ':' + $client.Port + '/api/v2/app/setPreferences'
    $param = @{ json = ( @{ $param = $value } | ConvertTo-Json -Compress ) }
    Invoke-WebRequest -Uri $url -WebSession $client.sid -Body $param -Method POST | Out-Null

}

function Write-Log ( $str ) {
    if ( $use_timestamp -ne 'Y' ) {
        Write-Host $str
    }
    else {
        Write-Host ( ( Get-Date -Format 'dd-MM-yyyy HH:mm:ss' ) + ' ' + $str )
    }
}