Write-Host 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"
. "$PSScriptRoot\_settings.ps1"

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

$clients = @{}
Write-Host 'Получаем из TLO данные о клиентах'
$ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
    $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
    $clients_sort = [ordered]@{}
    $clients.GetEnumerator() | Sort-Object -Property key | ForEach-Object { $clients_sort[$_.key] = $clients[$_.key] }
    $clients = $clients_sort
    Remove-Variable -Name clients_sort -ErrorAction SilentlyContinue
} 
$client = Select-Client
Write-host ( 'Выбран клиент ' + $client.Name )
$path_from = Select-Path 'from'
$path_to = Select-Path 'to'
$category = Get-String $false 'Укажите категорию (при необходимости)'
Initialize-Client $client
if ( $client.sid ) {
    $i = 0
    $torrents_list = Get-Torrents $client '' | Where-Object { $_.save_path -match "${path_from}" }
    if ( $category -and $category -ne '' ) {
        $torrents_list = $torrents_list  | Where-Object { $_.category -eq "${category}" }
    }
    foreach ( $torrent in $torrents_list) {
        $i++
        $new_path = $torrent.save_path -replace ( $path_from, $path_to )
        if ( $new_path -ne $torrent.save_path ) {
            Set-Location $client $torrent $new_path
            Write-Progress -Activity 'Moving' -Status $torrent.name -PercentComplete ( $i * 100 / $torrents_list.Count )
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Progress -Activity 'Moving' -Completed
}
