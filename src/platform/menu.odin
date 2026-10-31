package platform

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

Player_Menu :: struct {
	is_driving: proc() -> bool,
	toggle:     proc(),
}

@(private)
player_menu: Player_Menu

@(private)
player_menu_item: ^NS.MenuItem

install_player_menu :: proc(player: Player_Menu) {
	player_menu = player

	empty_key := NS.String.alloc()->initWithOdinString("")
	app_item := NS.MenuItem.alloc()->initWithTitle(
		NS.String.alloc()->initWithOdinString("onlymuse"),
		nil,
		empty_key,
	)
	app_menu := NS.Menu.alloc()->initWithTitle(NS.String.alloc()->initWithOdinString("onlymuse"))
	player_menu_item =
	NS.MenuItem.alloc()->initWithTitle(
		NS.String.alloc()->initWithOdinString("Play in Music.app"),
		intrinsics.objc_find_selector("togglePlayerMode:"),
		empty_key,
	)
	NS.MenuItem_setTarget(player_menu_item, state.target)
	NS.Menu_addItem(app_menu, player_menu_item)
	NS.Menu_addItem(app_menu, NS.MenuItem_separatorItem())

	quit_item := NS.MenuItem.alloc()->initWithTitle(
		NS.String.alloc()->initWithOdinString("Quit onlymuse"),
		intrinsics.objc_find_selector("quitApp:"),
		NS.String.alloc()->initWithOdinString("q"),
	)
	NS.MenuItem_setTarget(quit_item, state.target)
	NS.Menu_addItem(app_menu, quit_item)

	main_menu := NS.Menu.alloc()->initWithTitle(NS.String.alloc()->initWithOdinString("onlymuse"))
	NS.Menu_addItem(main_menu, app_item)
	NS.Menu_setSubmenu(main_menu, app_menu, app_item)
	state.app->setMainMenu(main_menu)
}
