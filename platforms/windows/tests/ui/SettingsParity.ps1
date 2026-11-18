# Проверяет установленный русскоязычный Tutun с работающей службой. Запустить из интерактивной Windows PowerShell.
# Источники ожидаемого поведения: AboutPane.swift, SettingsView.swift, AddSheet.swift и MainView.swift.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$scope = [Windows.Automation.TreeScope]::Descendants
$invoke = [Windows.Automation.InvokePattern]::Pattern
$desktop = [Windows.Automation.AutomationElement]::RootElement

function Find-Label($parent, [string]$name) {
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::NameProperty), $name
    return $parent.FindFirst($scope, $condition)
}
function Find-Window([string]$name) {
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ControlTypeProperty), ([Windows.Automation.ControlType]::Window)
    return $desktop.FindAll($scope,$condition) | Where-Object { $_.Current.Name -eq $name -and $_.Current.ProcessId -eq $app.Id } | Select-Object -First 1
}
function Test-Label($parent, [string]$name, [bool]$expected = $true) {
    if ([bool](Find-Label $parent $name) -ne $expected) { throw "Неожиданное состояние элемента «$name». Ожидалось присутствие: $expected" }
}
function Press($parent, [string]$name) {
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::NameProperty), $name
    $deadline = (Get-Date).AddSeconds(6)
    do {
        foreach ($candidate in $parent.FindAll($scope, $condition)) {
            $element = $candidate
            while ($element -and $element -ne $parent) {
                $pattern = $null
                if ($element.TryGetCurrentPattern($invoke,[ref]$pattern)) {
                    $pattern.Invoke()
                    Start-Sleep -Milliseconds 600
                    return
                }
                $element = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Кнопка «$name» не найдена"
}
$app = Get-Process Tutun | Where-Object MainWindowHandle | Select-Object -First 1
if (!$app) { throw 'Откройте главное окно Tutun' }
$window = Find-Window 'Tutun'
if (!(Find-Label $window 'О Tutun')) { Press $window 'Настройки' }
Press $window 'О Tutun'
foreach ($label in 'Проверить обновления','Служба','Состояние','Перезапусков ядра','Переустановить службу','Удалить службу','Сохранить диагностический отчёт…','Проект') {
    Test-Label $window $label
}
'ABOUT_SERVICE_OK'
Press $window 'Ещё'
Test-Label $window 'Переустановить службу' $false
foreach ($label in 'Соединения','Статистика','Журнал') {
    Press $window $label
    $tool = Find-Window $label
    if (!$tool) { throw "Окно «$label» не открылось" }
    $tool.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
    Start-Sleep -Milliseconds 500
}
'MORE_TOOLS_OK'
Press $window 'Сеть'
Test-Label $window 'Раздавать VPN другим устройствам'
Press $window 'Маршруты'
Test-Label $window 'Гео-базы'
Test-Label $window 'Обновить сейчас'
'NETWORK_AND_ROUTES_OK'
Press $window 'Добавить'
foreach ($label in 'Из буфера','QR с экрана','QR-картинка','Файл','Отмена') { Test-Label $window $label }
'IMPORT_OK'
Press $window 'Серверы'
Test-Label $window 'Самый быстрый'
if (Find-Label $window 'Информация о подписке') {
    Test-Label $window 'Проверить задержку'
    Test-Label $window 'Обновить подписку'
    Test-Label $window 'Вид и сортировка'
    'SUBSCRIPTION_TOOLS_OK'
}
Press $window 'Настройки'
Press $window 'О Tutun'
'PASS'
