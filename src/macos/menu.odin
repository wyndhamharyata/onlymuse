package macos

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

Player_Menu :: struct {
	is_driving: proc() -> bool,
	toggle:     proc(),
}

// Puts "Play in Music.app" at the top of the app menu thor made.
install_player_menu :: proc(player: Player_Menu) {
	state.player_menu = player

	state.player_menu_item = NS.MenuItem.alloc()->initWithTitle(
		NS.String.alloc()->initWithOdinString("Play in Music.app"),
		intrinsics.objc_find_selector("togglePlayerMode:"),
		NS.String.alloc()->initWithOdinString(""),
	)
	NS.MenuItem_setTarget(state.player_menu_item, state.target)

	bar := objc_send(^NS.Menu, NS.Application.sharedApplication(), "mainMenu")
	app_menu := objc_send(^NS.Menu, NS.Menu_itemAtIndex(bar, 0), "submenu")
	NS.Menu_insertItem(app_menu, state.player_menu_item, 0)
	NS.Menu_insertItem(app_menu, NS.MenuItem_separatorItem(), 1)
}
