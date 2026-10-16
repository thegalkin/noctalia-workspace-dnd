--!nonstrict
-- Workspace DnD — bar button.
--
-- Noctalia does not allow drag sources on bar widgets, so the bar only carries a
-- button that opens the drag & drop panel.

local PANEL = "thegalkin/workspace-dnd:panel"

function onClick()
  noctalia.togglePanel(PANEL)
end

barWidget.setGlyph("layout-grid")
barWidget.setTooltip(noctalia.tr("widget.tooltip"))
