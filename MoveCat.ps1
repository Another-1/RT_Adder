Write-Output 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}
Write-Output 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"

if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
    Install-Module -Name PsIni -Scope CurrentUser -Force
}
if ( -not ( [bool](Get-InstalledModule -Name PSSQLite -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSSQLite для получения данных из базы Web-TLO, ставим...'
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}

If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" ) ) {
    Set-Preferences
}
else { . "$PSScriptRoot\_settings.ps1" }

Write-Output 'Читаем настройки Web-TLO'

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path
$clients = @{}

Write-Output 'Получаем из TLO данные о клиентах'
$ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
    $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
} 
$clients_sort = [ordered]@{}
$clients.GetEnumerator() | Sort-Object -Property key | ForEach-Object { $clients_sort[$_.key] = $clients[$_.key] }
$clients = $clients_sort
Remove-Variable -Name clients_sort -ErrorAction SilentlyContinue

# Скрипт спрашивает в каком клиенте хозяйничать
$client = Select-Client

# Скрипт спрашивает ID раздела (обязательное)
$section_id = Get-String $true 'Укажите ID раздела'

# Скрипт спрашивает старый путь (необязательное)
$path_from = Get-String $false 'Укажите старый путь'

# Скрипт спрашивает новый путь (необязательное)
$path_to = Get-String $false 'Укажите новый путь'

# Скрипт спрашивает новое название категории (необязательное)
$cat_to = Get-String $false 'Укажите новую категорию'

# Если новый путь и новое название категории пустые - скрипт завершает работу
if ( $path_to -eq '' -and $cat_to -eq '' ) {
    Write-Host 'Нужно указать новый путь или новую категорию' -ForegroundColor Red
    Exit
}

# Скрипт вытягивает из клиента все раздачи
Initialize-Client $client
$client_torrents = Get-Torrents $client '' $false $nul $clientkey

# Скрипт вытягивает из БД WebTLO хэши раздач с введённым ID раздела
$db_hashes = @{}
Get-DBHashesBySecton $section_id | Select-Object hs -ExpandProperty hs | ForEach-Object { $db_hashes[$_] = 1 } 

# Скрипт фильтрует раздачи, оставляя только те, которые относятся к выбранному разделу
$client_torrents = $client_torrents | Where-Object { $db_hashes[$_.hash.toUpper()] }

# Если задан старый путь - скрипт фильтрует все раздачи у которых нет в старого пути в папке сохранения
If ( $path_from -ne '') { $client_torrents = $client_torrents | Where-Object { -not ( $_.save_path.contains( $path_from ) ) } }

# Для каждого торрента из оставшихся
foreach ( $torrent in $client_torrents ) {

    # Если задан новый путь
    if ( $path_to -ne '' ) {

        # Если задан старый путь
        if ( $path_from -ne '' ) {

            # Заменить в пути раздачи старый путь на новый
            # Переместить раздачу в полученную папку
            Set-SaveLocation $client $torrent $torrent.save_path.Replace( $path_from, $path_to ) $true
        }
        
        # иначе
        else {
            # Переместить раздачу в новый путь
            Set-SaveLocation $client $torrent $path_to $true
        }
    }

    # Если задано новое название категории
    if ( $cat_to -ne '' ) {
        # Задать новое название категории
        Set-TorrentCategory $client $torrent $cat_to $true
    }
}

