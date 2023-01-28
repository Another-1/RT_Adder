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
function Select-Path ( $direction ) {
    # $defaultTo = 'Хранимые'
    if ( $direction -eq 'from' ) {
        $default = 'Хранимое'
        $str = "Выберите исходный кусок пути [$default]"
    }
    else {
        $default = 'Хранимые'
        $str = "Выберите целевой кусок пути [$default]]"
    } 
    $choice = Read-Host $str
    $result = ( $default, $choice)[[bool]$choice]
    return $result
}
function Get-Disk {
    $choice = ( Read-Host 'Укажите букву диска (при необходимости)' ).ToUpper()
    if ( $choice ) { return $choice } else { return '' }
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

function Convert-Path ( $path ) {
    if ( $env:COMPUTERNAME -ne $client.CompName ) {
        $path = '\\' + $client.CompName + '\' + $path.replace( ':', '')
    }
    return $path
}

function  Set-Location ( $client, $torrent, $new_path ) {
    Write-Host ( 'Перемещаем ' + $torrent.name )
    # if ( $env:COMPUTERNAME -ne $client.CompName ) {
    #     $new_folder_path = '\\' + $client.CompName + '\' + $new_path.replace( ':', '')
    # }
    # else { $new_folder_path = $new_path }
    $smb_path = Convert-Path $new_path
    New-Item -ItemType Directory -Path $smb_path -ErrorAction SilentlyContinue | Out-Null
    $data = @{
        hashes   = $torrent.hash
        location = $new_path
    }
    Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/setLocation' ) -WebSession $client.sid -Body $data -Method POST | Out-Null
}

function Get-TopicIDs ( $client, $torrent_list ) {
    Write-Host 'Ищем ID'
    $query = 'CREATE TABLE IF NOT EXISTS TOPICS ( hash VARCHAR(40) NOT NULL PRIMARY KEY, id INT NOT NULL )'
    Invoke-SqliteQuery -Query $query -SQLiteConnection $conn
    $dbdata = @{}
    Invoke-SqliteQuery -Query "SELECT * FROM TOPICS" -SQLiteConnection $conn | ForEach-Object { $dbdata[$_.hash] = $_.id }
    $new_ids = @()
    $torrent_list | ForEach-Object {
        $i = 1
        $Params = @{ hash = $_.hash }
        $_.topic_id = $dbdata[ $_.hash ]
        if ($nul -eq $_.topic_id) {
            while ( $true ) {
                # Remove-Variable -Name $torrent_list -ErrorAction SilentlyContinue
                try {
                    $comment = ( Invoke-WebRequest -uri ( $client.ip + ':' + $client.Port + '/api/v2/torrents/properties' ) -WebSession $client.sid -Body $params ).Content | ConvertFrom-Json | Select-Object comment -ExpandProperty comment
                    if ( $comment -match 'rutracker' ) {
                        $_.topic_id = ( Select-String "\d*$" -InputObject $comment ).Matches.Value
                        $new_ids += [PSCustomObject]@{ hash = $_.hash; id = $_.topic_id }
                    }
                    break
                }
                catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
            }
        }
    }
    if ( $new_ids.Count -gt 0 ) {
        $new_ids = $new_ids | Out-DataTable
        Invoke-SQLiteBulkCopy -DataTable $new_ids -SQLiteConnection $conn -Table topics -Force
    }
}

function Initialize-Forum () {
    if ( !$forum ) {
        Write-Host 'Не обнаружены данные для подключения к форуму. Проверьте настройки.' -ForegroundColor Red
        Exit
    }
    Write-Host 'Авторизуемся на форуме.'

    # $login_url = 'http://rutracker.org/forum/login.php'
    $login_url = 'https://rutracker.net/forum/login.php'
    $headers = @{ 'User-Agent' = 'Mozilla/5.0' }
    $payload = @{ 'login_username' = $forum.login; 'login_password' = $forum.password; 'login' = '%E2%F5%EE%E4' }
    $i = 1

    while ($true) {
        try {
            $forum_auth = Invoke-WebRequest -Uri $login_url -Method Post -Headers $headers -Body $payload -SessionVariable sid -MaximumRedirection 999 -ErrorAction Ignore -SkipHttpErrorCheck
            $match = Select-String "form_token: '(.*)'" -InputObject $forum_auth.Content
            # $forum_token = $match.Matches.Groups[1].Value
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
    $forum.token = $forum_token
    $forum.sid = $sid
    Write-Host ( 'Успешно. Токен: [{0}]' -f $forum_token )
}

function Get-ForumTorrentFile ( [int]$Id ) {
    if ( !$forum.sid ) { Initialize-Forum }
    $forum_url = 'https://rutracker.net/forum/dl.php?t=' + $Id
    $Path = $PSScriptRoot + '\' + $Id + '_' + $Type + '.torrent'
    $i = 1
    while ( $true ) {
        try { Invoke-WebRequest -uri $forum_url -WebSession $forum.sid -OutFile $Path ; break }
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
            $ForumName = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/get_forum_data?by=forum_id&val=$section" ).content | ConvertFrom-Json -AsHashtable ).result[$section].forum_name
            break
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    return $ForumName
}

function Remove-ClientTorrent ( $client, $hash, $deleteFiles ) {
    try {
        if ( $deleteFiles -eq $true ) {
            Write-Host ( 'Удаляем из клиента ' + $client.Name + ' раздачу ' + $hash + ' полностью')
        }
        else {
            Write-Host ( 'Удаляем из клиента ' + $client.Name + ' раздачу ' + $hash + ' слегка')
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

function Get-TorrentName ( $hash, $topic_id ) {
    $request = @{ 'by' = 'hash'; 'val' = $hash }
    $i = 1
    while ($true) {
        try {
            $name = ( ( Invoke-WebRequest -Uri 'https://api.t-ru.org/v1/get_tor_topic_data' -Body $request ).content | ConvertFrom-Json -AsHashtable).result[$topic_id.ToString()].topic_title
            break
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    return $name
}

function Send-Report {
    $in_progress = Test-Path -Path "$PSScriptRoot\in_progress.lck"
    if ( !$in_progress ) {
        New-Item -Path "$PSScriptRoot\in_progress.lck" | Out-Null
        Write-Host 'Обновляем БД'
        . c:\OpenServer\modules\php\PHP_8.1\php.exe c:\OpenServer\domains\webtlo.local\cron\update.php
        Write-Host 'Шлём отчёт'
        . c:\OpenServer\modules\php\PHP_8.1\php.exe c:\OpenServer\domains\webtlo.local\cron\reports.php
        Remove-Item "$PSScriptRoot\in_progress.lck" 
    }
}