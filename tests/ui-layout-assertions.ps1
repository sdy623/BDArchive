# Included only by -SmokeTest. These checks inspect actual WinForms rectangles;
# they do not change Windows DPI settings or trigger any archive operation.
function Assert-UiLayout($Container) {
    if ($Container -is [Windows.Forms.TableLayoutPanel] -or $Container -is [Windows.Forms.FlowLayoutPanel]) {
        $children=@($Container.Controls | Where-Object { $_.Visible })
        for ($i=0;$i -lt $children.Count;$i++) {
            $a=$children[$i]
            if ($a.Width -le 0 -or $a.Height -le 0) { throw "Collapsed control: $($a.GetType().Name) $($a.Text)" }
            for ($j=$i+1;$j -lt $children.Count;$j++) {
                if ($a.Bounds.IntersectsWith($children[$j].Bounds)) { throw "Overlapping controls: $($a.Text) $($a.Bounds) / $($children[$j].Text) $($children[$j].Bounds); container=$($Container.Size)" }
            }
            if ($a -is [Windows.Forms.Button]) {
                $preferred=$a.GetPreferredSize([Drawing.Size]::Empty)
                if ($a.Width -lt $preferred.Width -or $a.Height -lt $preferred.Height) { throw "Clipped button: $($a.Text)" }
            }
        }
    }
    foreach ($child in $Container.Controls) { if ($child.Visible) { Assert-UiLayout $child } }
}
function Assert-UiReachable($Page,$Control) {
    # AutoScroll is allowed: every action must be reachable after scrolling.
    Show-UiControl $Control;[Windows.Forms.Application]::DoEvents()
    $viewport=$Control.Parent
    while($viewport -and !($viewport -is [Windows.Forms.ScrollableControl] -and $viewport.AutoScroll)){$viewport=$viewport.Parent}
    if($viewport){
        $inner=$viewport.RectangleToClient($Control.RectangleToScreen($Control.ClientRectangle))
        if(!$viewport.ClientRectangle.Contains($inner)){throw "Control clipped in content viewport: $($Control.Text) ($inner)"}
    }
    $rect=$Page.RectangleToClient($Control.RectangleToScreen($Control.ClientRectangle))
    if (!$Page.ClientRectangle.Contains($rect)) { throw "Control cannot be reached in viewport: $($Control.Text) ($rect)" }
}
