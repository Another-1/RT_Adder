# Settings
$max_rehash_qty = 10 # (максимальное количество отправляемых в рехэш раздач за один прогон)
$max_rehash_size_bytes = 10 * 1024 * 1024 * 1024 # 10 гигов (максимальный объём отправляемых в рехэш раздач за один прогон в байтах)
$frequency = 365.25 # (минимальное время между рехэшами одной раздачи в днях)
$use_timestamp = 'Y' # (добавлять или нет отметку даты времени к журналу в консоли)
$rehash_freshes = 'N' # (отправлять или нет в рехэш раздачи, скачанные менее чем $frequency назад (см. выше))
$wait_finish = 'Y' # (ожидать ли окончания рехэша раздач с отчётом в телеграм и в журнал о найденных битых и с простановкой им тега "Битая")

# Code
New-Item -Path ( $PSScriptRoot + $separator + 'rehasher.lck') -ErrorAction SilentlyContinue | Out-Null

$str = 'Подгружаем функции' 
if ( $use_timestamp -ne 'Y' ) { Write-Host $str } else { Write-Host ( ( Get-Date -Format 'dd-MM-yyyy HH:mm:ss' ) + ' ' + $str ) }

. "$PSScriptRoot\_functions.ps1"

$separator = Get-Separator
if ( Test-Path -Path ( $PSScriptRoot + $separator + 'rehasher.lck') ) {
    Write-Host 'Обнаружен файл блокировки, выходим' -ForegroundColor Red
    exit
}

Write-Log 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}

if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
    Write-Log 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
    Install-Module -Name PsIni -Scope CurrentUser -Force
}
if ( -not ( [bool](Get-InstalledModule -Name PSSQLite -ErrorAction SilentlyContinue) ) ) {
    Write-Log 'Не установлен модуль PSSQLite для работы с SQLite, ставим...'
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}

If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" )) {
    Set-Preferences # $tlo_path $max_seeds $get_hidden $get_blacklist $get_news $tg_token $tg_chat
}
else { . "$PSScriptRoot\_settings.ps1" }

if ( !$max_rehash_qty -or !$max_rehash_size_bytes ) {
    Write-Log 'Задайте ограничения на пачку в _settings.ps1 или во мне самом' -ForegroundColor Red
    exit
}

$max_repeat_epoch = ( Get-Date -UFormat %s ).ToInt32($null) - ( $frequency * 24 * 60 * 60 ) # количество секунд между повторными рехэшами одной раздачи

Write-Log 'Читаем настройки Web-TLO'

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

Write-Log 'Получаем из TLO данные о клиентах'
$clients = @{}
$ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
    $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
} 

$clients_torrents = @()

foreach ($clientkey in $clients.Keys ) {
    $client = $clients[ $clientkey ]
    Initialize-Client( $client )
    $client_torrents = Get-Torrents $client '' $true $null $clientkey
    $clients_torrents += $client_torrents
}

Write-Log 'Исключаем уже хэшируемые и стояшие в очереди на рехэш'
$before = $clients_torrents.count
$clients_torrents = $clients_torrents | Where-Object { $_.state -ne 'checkingUP' }
Write-Log ( 'Исключено раздач: ' + ( $before - $clients_torrents.count ) )

if ( $rehash_freshes -ne 'Y') {
    $before = $clients_torrents.count
    Write-Log 'Исключаем свежескачанные раздачи'
    $clients_torrents = $clients_torrents | Where-Object { $_.completion_on -le $max_repeat_epoch }
    Write-Log ( 'Исключено раздач: ' + ( $before - $clients_torrents.count ) )
}

$db_data = @{}
$database_path = $PSScriptRoot + $separator + 'rehashes.db'
Write-Log 'Подключаемся к БД'
$conn = Open-Database $database_path
Invoke-SqliteQuery -Query 'CREATE TABLE IF NOT EXISTS rehash_dates (hash VARCHAR PRIMARY KEY NOT NULL, rehash_date INT)' -SQLiteConnection $conn
Write-Log 'Выгружаем из БД даты рехэшей'
Invoke-SqliteQuery -Query 'SELECT * FROM rehash_dates' -SQLiteConnection $conn | ForEach-Object { $db_data += @{$_.hash = $_.rehash_date } }

$full_data_sorted = [System.Collections.ArrayList]::new()
Write-Log 'Ищем раздачи из клиентов в БД рехэшей'
$clients_torrents | ForEach-Object {
    if ( !$_.infohash_v1 -or $nul -eq $_.infohash_v1 -or $_.infohash_v1 -eq '' ) { $_.infohash_v1 = $_.hash }
    if ($_.infohash_v1 -and ( $nul -ne $_.infohash_v1 ) -and ( $_.infohash_v1 -ne '' ) ) {
        $full_data_sorted.Add( [PSCustomObject]@{ hash = $_.infohash_v1; rehash_date = $( $null -ne $db_data[$_.infohash_v1] -and $db_data[$_.infohash_v1] -gt 0 ? $db_data[$_.infohash_v1] : 0 ); client_key = $_.client_key; size = $_.size; name = $_.name } ) | Out-Null
    }
}

Write-Log 'Исключаем раздачи, которые рано рехэшить'
$before = $full_data_sorted.count
$full_data_sorted = $full_data_sorted | Where-Object { $_.rehash_date -lt $max_repeat_epoch }
Write-Log ( 'Исключено раздач: ' + ( $before - $full_data_sorted.count ) )

Write-Log 'Сортируем всё по дате рехэша и размеру'
$full_data_sorted = $full_data_sorted | Sort-Object -Property size -Descending | Sort-Object -Property rehash_date -Stable

$sum_cnt = 0
$sum_size = 0
foreach ( $torrent in $full_data_sorted ) {
    if ( $wait_finish -eq 'Y' ) {
        Write-Log ( 'Будем рехэшить торрент "' + $torrent.name + '" в клиенте ' + $clients[$torrent.client_key].Name + ' но сначала запомним его состояние и при необходимости остановим')
        $prev_state = ( Get-Torrents $clients[$torrent.client_key] '' $false $torrent.hash $null $false ).state
        if ( $prev_state -eq 'pausedUP') { Write-Log 'Торрент остановлен, так и запишем' } else { Write-Log 'Торрент запущен, так и запишем' }
        if ( $prev_state -ne 'pausedUP' ) {
            Write-Log ( 'Останавливаем ' + $torrent.name + ' в клиенте ' + $clients[$torrent.client_key].Name )
            Stop-Torrents $torrent.hash $clients[$torrent.client_key]
        }
    }
    Write-Log ( 'Отправляем в рехэш ' + $torrent.name + ' в клиенте ' + $clients[$torrent.client_key].Name )
    Start-Rehash $clients[$torrent.client_key] $torrent.hash
    if ( !$db_data[$torrent.hash] ) {
        Invoke-SqliteQuery -Query "INSERT INTO rehash_dates (hash, rehash_date) VALUES (@hash, @epoch )" -SqlParameters @{ hash = $torrent.hash; epoch = ( Get-Date -UFormat %s ) }-SQLiteConnection $conn
    }
    else {
        Invoke-SqliteQuery -Query "UPDATE rehash_dates SET rehash_date = @epoch WHERE hash = @hash" -SqlParameters @{ hash = $torrent.hash; epoch = ( Get-Date -UFormat %s ) } -SQLiteConnection $conn
    }
    $sum_cnt += 1
    $sum_size += $torrent.size
    if ( $wait_finish -eq 'Y' ) {
        Start-Sleep -Seconds 2
        Write-Log 'Подождём окончания рехэша'
        while ( ( Get-Torrents $clients[$torrent.client_key] '' $false $torrent.hash $null $false ).state -like 'checking*' ) {
            Start-Sleep -Seconds 5
        }
        if ( ( Get-Torrents $clients[$torrent.client_key] '' $false $torrent.hash $null $false ).progress -lt 1 ) {
            Write-Log ( 'Раздача ' + $torrent.name + ' битая! Запускаем докачку' )
            Start-Torrents $torrent.hash $clients[$torrent.client_key]
            Set-Comment $clients[$torrent.client_key] $torrent 'Битая'
            $message = 'Битая раздача ' + $torrent.name + ' в клиенте http://' + $clients[$torrent.client_key].IP + ':' + $clients[$torrent.client_key].Port
            Send-TGMessage $message $tg_token $tg_chat
        }
        else {
            Write-Log ( 'Раздача ' + $torrent.name + ' в порядке' )
            if ( $prev_state -ne 'pausedUP' ) { Start-Torrents $torrent.hash $clients[$torrent.client_key] }
        }
    }

    if ( $sum_cnt -ge $max_rehash_qty -or $sum_size -ge $max_rehash_size_bytes) {
        break
    }
}

Write-Log 'Прогон завершён'
Write-Log ( "Отправлено в рехэш: $sum_cnt раздач объёмом " + [math]::Round( $sum_size / 1024 / 1024 / 1024, 2 ) + ' ГБ' )
Write-Log ( 'Осталось: ' + ( $full_data_sorted.count - $sum_cnt ) + ' раздач объёмом ' + [math]::Round( ( ( $full_data_sorted | Measure-Object -Property size -Sum ).Sum - $sum_size ) / 1024 / 1024 / 1024, 2 ) + ' ГБ' )

$conn.Close()
Remove-Item -Path ( $PSScriptRoot + $separator + 'rehasher.lck') | Out-Null
