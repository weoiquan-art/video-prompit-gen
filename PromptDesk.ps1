#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest

function Get-PromptDeskDataPath {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    Join-Path (Join-Path $appData 'PromptDesk') 'prompts.json'
}

function ConvertTo-PromptRecord {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $id = [string]$Value.Id
    if ([string]::IsNullOrWhiteSpace($id)) {
        $id = [Guid]::NewGuid().ToString('N')
    }

    [pscustomobject]@{
        Id        = $id
        Title     = [string]$Value.Title
        Content   = [string]$Value.Content
        UpdatedAt = [string]$Value.UpdatedAt
    }
}

function Read-PromptFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "提示词文件为空：$Path"
    }

    $parsed = $json | ConvertFrom-Json
    $values = $parsed
    if ($null -ne $parsed.prompts) {
        $values = $parsed.prompts
    }

    @($values | ForEach-Object {
        ConvertTo-PromptRecord $_
    } | Where-Object { $null -ne $_ })
}

function Load-PromptData {
    param([Parameter(Mandatory = $true)][string]$Path)

    $backupPath = "$Path.bak"
    if (-not (Test-Path -LiteralPath $Path)) {
        if (Test-Path -LiteralPath $backupPath) {
            return Read-PromptFile -Path $backupPath
        }
        return @()
    }

    try {
        return Read-PromptFile -Path $Path
    }
    catch {
        if (Test-Path -LiteralPath $backupPath) {
            try {
                return Read-PromptFile -Path $backupPath
            }
            catch {
                throw "无法读取提示词文件：$Path；备份也无法读取。"
            }
        }
        throw "无法读取提示词文件：$Path。"
    }
}

function Save-PromptData {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Prompts
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $document = [pscustomobject]@{
        version = 1
        prompts = @($Prompts)
    }
    $json = ConvertTo-Json -InputObject $document -Depth 5
    $tempPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.bak"
    $utf8NoBom = New-Object Text.UTF8Encoding($false)

    try {
        [IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($tempPath, $Path, $backupPath, $true)
        }
        else {
            [IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Search-Prompts {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Prompts,
        [AllowEmptyString()][string]$Query
    )

    $query = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($query)) {
        return @($Prompts)
    }

    @($Prompts | Where-Object {
        $title = [string]$_.Title
        $content = [string]$_.Content
        $title.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $content.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

function Assert-SelfTest {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "SelfTest 失败：$Message"
    }
}

function Invoke-PromptDeskSelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) "PromptDesk-SelfTest-$([Guid]::NewGuid().ToString('N'))"
    $path = Join-Path $root 'prompts.json'

    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $first = [pscustomobject]@{
            Id        = 'one'
            Title     = '旅行镜头'
            Content   = '夜晚城市，慢推镜头'
            UpdatedAt = '2026-01-01T00:00:00Z'
        }
        $second = [pscustomobject]@{
            Id        = 'two'
            Title     = '产品特写'
            Content   = '柔和光线，突出材质'
            UpdatedAt = '2026-01-01T00:00:00Z'
        }

        Save-PromptData -Path $path -Prompts @($first, $second)
        $loaded = @(Load-PromptData -Path $path)
        Assert-SelfTest ($loaded.Count -eq 2) '保存和读取数量不一致'
        Assert-SelfTest ($loaded[0].Content -eq $first.Content) '多行内容读取不一致'

        $titleHits = @(Search-Prompts -Prompts $loaded -Query '旅行')
        $contentHits = @(Search-Prompts -Prompts $loaded -Query '材质')
        $allHits = @(Search-Prompts -Prompts $loaded -Query '')
        Assert-SelfTest ($titleHits.Count -eq 1 -and $titleHits[0].Id -eq 'one') '标题搜索失败'
        Assert-SelfTest ($contentHits.Count -eq 1 -and $contentHits[0].Id -eq 'two') '内容搜索失败'
        Assert-SelfTest ($allHits.Count -eq 2) '空搜索失败'

        $emptyPath = Join-Path $root 'empty.json'
        Save-PromptData -Path $emptyPath -Prompts @()
        Assert-SelfTest (@(Load-PromptData -Path $emptyPath).Count -eq 0) '空列表保存失败'
        Assert-SelfTest (@(Search-Prompts -Prompts @() -Query '没有').Count -eq 0) '空列表搜索失败'

        $first.Content = "已更新`n第二行"
        Save-PromptData -Path $path -Prompts @($first, $second)
        $backupPath = "$path.bak"
        Assert-SelfTest (Test-Path -LiteralPath $backupPath) '没有生成备份文件'
        $updated = @(Load-PromptData -Path $path)
        Assert-SelfTest ($updated[0].Content -like '已更新*') '二次保存失败'

        Write-Output 'SelfTest passed: storage, backup, and search.'
    }
    finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-PromptDesk {
    param([Parameter(Mandatory = $true)][string]$DataPath)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = [Threading.Mutex]::new($false, "Local\PromptDesk-$sid")
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (-not $hasLock) {
            [Windows.Forms.MessageBox]::Show('提示词本已经打开。', '提示词本', 'OK', 'Information') | Out-Null
            return
        }

    $form = New-Object Windows.Forms.Form
    $form.Text = '提示词收录'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object Drawing.Size(1000, 650)
    $form.MinimumSize = New-Object Drawing.Size(760, 480)
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)

    $toolbar = New-Object Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = 'Top'
    $toolbar.Height = 50
    $toolbar.Padding = New-Object Windows.Forms.Padding(8, 8, 8, 6)
    $toolbar.WrapContents = $false
    $toolbar.FlowDirection = 'LeftToRight'

    $searchLabel = New-Object Windows.Forms.Label
    $searchLabel.Text = '搜索'
    $searchLabel.AutoSize = $true
    $searchLabel.Margin = New-Object Windows.Forms.Padding(0, 7, 6, 0)

    $searchBox = New-Object Windows.Forms.TextBox
    $searchBox.Width = 300
    $searchBox.Margin = New-Object Windows.Forms.Padding(0, 1, 12, 0)

    $newButton = New-Object Windows.Forms.Button
    $newButton.Text = '新建'
    $newButton.AutoSize = $true
    $newButton.Margin = New-Object Windows.Forms.Padding(0, 0, 6, 0)

    $saveButton = New-Object Windows.Forms.Button
    $saveButton.Text = '保存'
    $saveButton.AutoSize = $true
    $saveButton.Margin = New-Object Windows.Forms.Padding(0, 0, 6, 0)

    $deleteButton = New-Object Windows.Forms.Button
    $deleteButton.Text = '删除'
    $deleteButton.AutoSize = $true

    [void]$toolbar.Controls.Add($searchLabel)
    [void]$toolbar.Controls.Add($searchBox)
    [void]$toolbar.Controls.Add($newButton)
    [void]$toolbar.Controls.Add($saveButton)
    [void]$toolbar.Controls.Add($deleteButton)

    $listPanel = New-Object Windows.Forms.Panel
    $listPanel.Dock = 'Left'
    $listPanel.Width = 300
    $listPanel.Padding = New-Object Windows.Forms.Padding(8, 8, 4, 8)

    $listLabel = New-Object Windows.Forms.Label
    $listLabel.Text = '提示词列表'
    $listLabel.Dock = 'Top'
    $listLabel.Height = 28

    $listBox = New-Object Windows.Forms.ListBox
    $listBox.Dock = 'Fill'
    $listBox.IntegralHeight = $false
    $listBox.DisplayMember = 'DisplayTitle'

    [void]$listPanel.Controls.Add($listBox)
    [void]$listPanel.Controls.Add($listLabel)

    $editor = New-Object Windows.Forms.Panel
    $editor.Dock = 'Fill'
    $editor.Padding = New-Object Windows.Forms.Padding(8, 8, 8, 8)

    $editorTable = New-Object Windows.Forms.TableLayoutPanel
    $editorTable.Dock = 'Fill'
    $editorTable.ColumnCount = 1
    $editorTable.RowCount = 5
    $editorTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))

    $titleLabel = New-Object Windows.Forms.Label
    $titleLabel.Text = '标题'
    $titleLabel.Dock = 'Fill'
    $titleLabel.TextAlign = 'MiddleLeft'

    $titleBox = New-Object Windows.Forms.TextBox
    $titleBox.Dock = 'Fill'

    $contentLabel = New-Object Windows.Forms.Label
    $contentLabel.Text = '提示词内容'
    $contentLabel.Dock = 'Fill'
    $contentLabel.TextAlign = 'MiddleLeft'

    $contentBox = New-Object Windows.Forms.RichTextBox
    $contentBox.Dock = 'Fill'
    $contentBox.Multiline = $true
    $contentBox.AcceptsTab = $true
    $contentBox.ScrollBars = 'Both'
    $contentBox.WordWrap = $false

    $editorFooter = New-Object Windows.Forms.FlowLayoutPanel
    $editorFooter.Dock = 'Fill'
    $editorFooter.FlowDirection = 'LeftToRight'
    $editorFooter.WrapContents = $false
    $editorFooter.Padding = New-Object Windows.Forms.Padding(0, 6, 0, 0)

    $copyButton = New-Object Windows.Forms.Button
    $copyButton.Text = '复制内容'
    $copyButton.AutoSize = $true
    $copyButton.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)

    $statusLabel = New-Object Windows.Forms.Label
    $statusLabel.AutoSize = $true
    $statusLabel.Text = '准备就绪'
    $statusLabel.Margin = New-Object Windows.Forms.Padding(0, 7, 0, 0)

    [void]$editorFooter.Controls.Add($copyButton)
    [void]$editorFooter.Controls.Add($statusLabel)

    $rowSizes = @(24, 32, 24, 0, 44)
    for ($i = 0; $i -lt $rowSizes.Count; $i++) {
        $rowStyle = New-Object Windows.Forms.RowStyle
        if ($i -eq 3) {
            $rowStyle.SizeType = [Windows.Forms.SizeType]::Percent
            $rowStyle.Height = 100
        }
        else {
            $rowStyle.SizeType = [Windows.Forms.SizeType]::Absolute
            $rowStyle.Height = $rowSizes[$i]
        }
        [void]$editorTable.RowStyles.Add($rowStyle)
    }
    [void]$editorTable.Controls.Add($titleLabel, 0, 0)
    [void]$editorTable.Controls.Add($titleBox, 0, 1)
    [void]$editorTable.Controls.Add($contentLabel, 0, 2)
    [void]$editorTable.Controls.Add($contentBox, 0, 3)
    [void]$editorTable.Controls.Add($editorFooter, 0, 4)
    [void]$editor.Controls.Add($editorTable)

    [void]$form.Controls.Add($editor)
    [void]$form.Controls.Add($listPanel)
    [void]$form.Controls.Add($toolbar)

    try {
        $loadedPrompts = @(Load-PromptData -Path $DataPath)
    }
    catch {
        [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '读取失败', 'OK', 'Error') | Out-Null
        $form.Dispose()
        return
    }

    $state = @{
        prompts    = $loadedPrompts
        current    = $null
        dirty      = $false
        suppress   = $false
        refreshing = $false
    }

    $refreshList = $null
    $loadCurrent = $null
    $saveCurrent = $null
    $beginNew = $null
    $confirmChanges = $null

    $refreshList = {
        $state.refreshing = $true
        try {
            $listBox.BeginUpdate()
            $listBox.Items.Clear()
            $query = $searchBox.Text
            $visible = @(Search-Prompts -Prompts $state.prompts -Query $query)
            foreach ($item in $visible) {
                Add-Member -InputObject $item -MemberType NoteProperty -Name DisplayTitle -Value $(if ([string]::IsNullOrWhiteSpace($item.Title)) { '(未命名)' } else { $item.Title }) -Force
                [void]$listBox.Items.Add($item)
            }

            if ($null -ne $state.current) {
                for ($index = 0; $index -lt $listBox.Items.Count; $index++) {
                    if ($listBox.Items[$index].Id -eq $state.current.Id) {
                        $listBox.SelectedIndex = $index
                        break
                    }
                }
            }
        }
        finally {
            $listBox.EndUpdate()
            $state.refreshing = $false
        }
    }.GetNewClosure()

    $loadCurrent = {
        param([object]$Item)
        $state.suppress = $true
        try {
            if ($null -eq $Item) {
                $titleBox.Text = ''
                $contentBox.Text = ''
                $state.current = $null
            }
            else {
                $titleBox.Text = [string]$Item.Title
                $contentBox.Text = [string]$Item.Content
                $state.current = $Item
            }
            $state.dirty = $false
        }
        finally {
            $state.suppress = $false
        }
        if ($null -eq $Item) {
            $statusLabel.Text = '新建提示词'
        }
        else {
            $statusLabel.Text = '已加载，可编辑'
        }
    }.GetNewClosure()

    $saveCurrent = {
        $title = $titleBox.Text.Trim()
        $content = $contentBox.Text
        if ([string]::IsNullOrWhiteSpace($title) -and [string]::IsNullOrWhiteSpace($content)) {
            [Windows.Forms.MessageBox]::Show($form, '请先填写标题或内容。', '无法保存', 'OK', 'Information') | Out-Null
            return $false
        }

        $now = (Get-Date).ToString('o')
        if ($null -eq $state.current) {
            $record = [pscustomobject]@{
                Id        = [Guid]::NewGuid().ToString('N')
                Title     = $title
                Content   = $content
                UpdatedAt = $now
            }
            $nextPrompts = @($state.prompts) + $record
        }
        else {
            $record = [pscustomobject]@{
                Id        = $state.current.Id
                Title     = $title
                Content   = $content
                UpdatedAt = $now
            }
            $nextPrompts = @($state.prompts | ForEach-Object {
                if ($_.Id -eq $record.Id) { $record } else { $_ }
            })
        }

        try {
            Save-PromptData -Path $DataPath -Prompts $nextPrompts
            $state.prompts = $nextPrompts
            $state.current = $record
            $state.dirty = $false
            & $refreshList
            $statusLabel.Text = '已保存'
            return $true
        }
        catch {
            $state.dirty = $true
            [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '保存失败', 'OK', 'Error') | Out-Null
            return $false
        }
    }.GetNewClosure()

    $beginNew = {
        $state.suppress = $true
        $state.refreshing = $true
        try {
            $state.current = $null
            $titleBox.Text = ''
            $contentBox.Text = ''
            $listBox.SelectedIndex = -1
            $state.dirty = $false
        }
        finally {
            $state.refreshing = $false
            $state.suppress = $false
        }
        $statusLabel.Text = '新建提示词'
        $titleBox.Focus()
    }.GetNewClosure()

    $confirmChanges = {
        if (-not $state.dirty) {
            return $true
        }

        $answer = [Windows.Forms.MessageBox]::Show(
            $form,
            '当前提示词有未保存修改，是否保存？',
            '未保存修改',
            'YesNoCancel',
            'Warning'
        )
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
            return (& $saveCurrent)
        }
        if ($answer -eq [Windows.Forms.DialogResult]::No) {
            if ($null -eq $state.current) {
                & $beginNew
            }
            return $true
        }
        $false
    }.GetNewClosure()

    $markDirty = {
        if (-not $state.suppress) {
            $state.dirty = $true
            $statusLabel.Text = '有未保存修改'
        }
    }.GetNewClosure()

    $searchBox.Add_TextChanged({ & $refreshList }.GetNewClosure())
    $titleBox.Add_TextChanged($markDirty)
    $contentBox.Add_TextChanged($markDirty)

    $listBox.Add_SelectedIndexChanged({
        if ($state.refreshing -or $null -eq $listBox.SelectedItem) {
            return
        }
        $target = $listBox.SelectedItem
        if ($null -ne $state.current -and $target.Id -eq $state.current.Id) {
            return
        }
        if (-not (& $confirmChanges)) {
            $state.refreshing = $true
            try {
                $listBox.SelectedIndex = -1
                if ($null -ne $state.current) {
                    for ($index = 0; $index -lt $listBox.Items.Count; $index++) {
                        if ($listBox.Items[$index].Id -eq $state.current.Id) {
                            $listBox.SelectedIndex = $index
                            break
                        }
                    }
                }
            }
            finally {
                $state.refreshing = $false
            }
            return
        }
        & $loadCurrent $target
        & $refreshList
    }.GetNewClosure())

    $newButton.Add_Click({
        if (& $confirmChanges) {
            & $beginNew
        }
    }.GetNewClosure())

    $saveButton.Add_Click({ & $saveCurrent }.GetNewClosure())

    $deleteButton.Add_Click({
        if ($null -eq $state.current) {
            return
        }
        if (-not (& $confirmChanges)) {
            return
        }
        $target = $state.current
        $remaining = @($state.prompts | Where-Object { $_.Id -ne $target.Id })
        $answer = [Windows.Forms.MessageBox]::Show($form, '确定删除当前提示词吗？', '确认删除', 'YesNo', 'Warning')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            return
        }
        try {
            Save-PromptData -Path $DataPath -Prompts $remaining
            $state.prompts = $remaining
            & $loadCurrent $null
            & $refreshList
            $statusLabel.Text = '已删除'
        }
        catch {
            [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '删除失败', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())

    $copyButton.Add_Click({
        if ([string]::IsNullOrEmpty($contentBox.Text)) {
            return
        }
        try {
            [Windows.Forms.Clipboard]::SetText($contentBox.Text)
            $statusLabel.Text = '内容已复制'
        }
        catch {
            [Windows.Forms.MessageBox]::Show($form, '复制失败，请重试。', '复制失败', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())

    $form.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Control -and $eventArgs.KeyCode -eq [Windows.Forms.Keys]::S) {
            & $saveCurrent
            $eventArgs.SuppressKeyPress = $true
        }
    }.GetNewClosure())
    $form.KeyPreview = $true

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $state.dirty) {
            return
        }
        $answer = [Windows.Forms.MessageBox]::Show(
            $form,
            '当前提示词有未保存修改，是否保存后退出？',
            '未保存修改',
            'YesNoCancel',
            'Warning'
        )
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
            if (-not (& $saveCurrent)) {
                $eventArgs.Cancel = $true
            }
        }
        elseif ($answer -eq [Windows.Forms.DialogResult]::Cancel) {
            $eventArgs.Cancel = $true
        }
    }.GetNewClosure())

    & $refreshList
    if ($listBox.Items.Count -gt 0) {
        $listBox.SelectedIndex = 0
    }
    else {
        & $beginNew
    }

    [void]$form.ShowDialog()
    $form.Dispose()
    }
    finally {
        if ($hasLock) {
            [void]$mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

if ($SelfTest) {
    try {
        Invoke-PromptDeskSelfTest
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

Start-PromptDesk -DataPath (Get-PromptDeskDataPath)

