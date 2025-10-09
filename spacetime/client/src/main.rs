mod module_bindings;
use std::io::Write;
use std::ptr::{null, null_mut};
use std::ffi::c_void;
// use std::os::raw::c_void;
use std::time::Instant;

use module_bindings::*;

use spacetimedb_sdk::{credentials, DbContext, Error, Event, Identity, Status, Table, TableWithPrimaryKey};

#[link(name = "render")] 
unsafe extern "C" {
    fn init() -> *mut c_void;
    fn deinit(window: *mut c_void);

    fn initPipeline() -> u32;
    fn deinitPipeline(program: u32);

    
    fn update(window: *mut c_void, delta_time: f32);
    fn draw(program: u32, window: *mut c_void);
    
    fn player_connect_local(id: u32) -> *mut c_void;
    fn player_connect_remote(id: u32) -> *mut c_void;
    fn update_player_pos(id: u32, pos: DbVector3) -> *mut c_void;


    fn is_key_down(key: u32, window: *mut c_void) -> bool;

    


}

/// The URI of the SpacetimeDB instance hosting our chat database and module.
// const HOST: &str = "http://localhost:3000";
const HOST: &str = "https://gorgeous-hygiene-respect-demand.trycloudflare.com/";

/// The database name we chose when we published our module.
const DB_NAME: &str = "zigma";


#[unsafe(no_mangle)]
pub extern "C" fn connect_to_db_ffi() -> *mut c_void {
    // Create the Rust DbConnection
    let conn = connect_to_db();

    // Box it and leak it so we can return a pointer
    Box::into_raw(Box::new(conn)) as *mut c_void
}

#[unsafe(no_mangle)]
pub extern "C" fn free_db_connection(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe {
            // Recover the Box and drop it
            Box::from_raw(ptr as *mut DbConnection);
        }
    }
}


/// Load credentials from a file and connect to the database.
fn connect_to_db() -> DbConnection {
    let token: Option<&str> = None;
    DbConnection::builder()
        // Register our `on_connect` callback, which will save our auth token.
        .on_connect(on_connected)
        // Register our `on_connect_error` callback, which will print a message, then exit the process.
        .on_connect_error(on_connect_error)
        // Our `on_disconnect` callback, which will print a message, then exit the process.
        .on_disconnect(on_disconnected)
        // If the user has previously connected, we'll have saved a token in the `on_connect` callback.
        // In that case, we'll load it and pass it to `with_token`,
        // so we can re-authenticate as the same `Identity`.
        // .with_token(creds_store().load().expect("Error loading credentials"))
        .with_token(token)
        // Set the database name we chose when we called `spacetime publish`.
        .with_module_name(DB_NAME)
        // Set the URI of the SpacetimeDB host that's running our database.
        .with_uri(HOST)
        // Finalize configuration and connect!
        .build()
        .expect("Failed to connect")
}

fn creds_store() -> credentials::File {
    credentials::File::new(DB_NAME)
}

/// Our `on_connect` callback: save our credentials to a file.
fn on_connected(_ctx: &DbConnection, _identity: Identity, token: &str) {
    if let Err(e) = creds_store().save(token) {
        eprintln!("Failed to save credentials: {:?}", e);
    }
}

/// Our `on_connect_error` callback: print the error, then exit the process.
fn on_connect_error(_ctx: &ErrorContext, err: Error) {
    eprintln!("Connection error: {:?}", err);
    std::process::exit(1);
}

/// Our `on_disconnect` callback: print a note, then exit the process.
fn on_disconnected(_ctx: &ErrorContext, err: Option<Error>) {
    if let Some(err) = err {
        eprintln!("Disconnected: {}", err);
        std::process::exit(1);
    } else {
        println!("Disconnected.");
        std::process::exit(0);
    }
}

fn on_player_inserted(_ctx: &EventContext, player: &Player) {
    println!("player {} connected.", player.identity);
        if _ctx.identity() == player.identity {
        unsafe {
            player_connect_local(player.player_id);
        };
    } else {
        unsafe {
            player_connect_remote(player.player_id);
        };
    }
}

fn on_player_update(_ctx: &EventContext, old_player: &Player, new_player: &Player) {
    println!("PLAYER UPDATED New x-Pos {}", new_player.position.x);
    unsafe {
        update_player_pos(new_player.player_id, new_player.position.clone());
    }
}

/// Register all the callbacks our app will use to respond to database events.
fn register_callbacks(ctx: &DbConnection) {
    println!("\nregister_callbacks\n");

    // When a new user joins, print a notification.
    ctx.db.player().on_insert(on_player_inserted);

    ctx.db.player().on_update(on_player_update);

    // // When a user's status changes, print a notification.
    // ctx.db.user().on_update(on_user_updated);

    // // When a new message is received, print it.
    // ctx.db.message().on_insert(on_message_inserted);

    // // When we fail to set our name, print a warning.
    // ctx.reducers.on_set_name(on_name_set);

    // // When we fail to send a message, print a warning.
    // ctx.reducers.on_send_message(on_message_sent);
}

fn on_sub_applied(ctx: &SubscriptionEventContext) {
    println!("Fully connected and all subscriptions applied.");
}

fn on_sub_error(_ctx: &ErrorContext, err: Error) {
    eprintln!("Subscription failed: {}", err);
    std::process::exit(1);
}

/// Register subscriptions for all rows of both tables.
fn subscribe_to_tables(ctx: &DbConnection) {
    ctx.subscription_builder()
        .on_applied(on_sub_applied)
        .on_error(on_sub_error)
        .subscribe(["SELECT * FROM player"]);
}


fn main() {
    // Connect to the database
    let ctx = connect_to_db();

    // Register callbacks to run in response to database events.
    register_callbacks(&ctx);
    
    // Subscribe to SQL queries in order to construct a local partial replica of the database.
    subscribe_to_tables(&ctx);

    // Spawn a thread, where the connection will process messages and invoke callbacks.
    ctx.run_threaded();

    // Handle CLI input
    // user_input_loop(&ctx);
    unsafe {
        let window = init();
        if window.is_null() {
            eprintln!("Failed to initialize window");
            return;
        }

        let pipeline = initPipeline();
        if pipeline == 0
        {
            eprintln!("Failed to initialize pipeline");
            deinit(window);

            return;
        }

        let mut last = Instant::now();

        loop {
            let now = Instant::now();
            let delta = (now - last).as_secs_f32();
            last = now;

            if is_key_down(0, window)
            {
                let cmd = Command::Move(MoveCommand { direction: {DbVector3 { x: (1.0), y: (0.0), z: (0.0) }}});
                _ = ctx.reducers.player_command(cmd);
            }
            else if is_key_down(1, window) {
                let cmd = Command::Move(MoveCommand { direction: {DbVector3 { x: (-1.0), y: (0.0), z: (0.0) }}});
                _ = ctx.reducers.player_command(cmd);
            }
            else if is_key_down(2, window) {
                let cmd = Command::Move(MoveCommand { direction: {DbVector3 { x: (0.0), y: (0.0), z: (-1.0) }}});
                _ = ctx.reducers.player_command(cmd);
            }
            else if is_key_down(3, window) {
                let cmd = Command::Move(MoveCommand { direction: {DbVector3 { x: (0.0), y: (0.0), z: (1.0) }}});
                _ = ctx.reducers.player_command(cmd);
            }

            update(window, delta);
            draw(pipeline, window);

            // you'll need a way to check if window.shouldClose()
            // one option: export a `should_close(window)` fn from Zig
        }
        deinit(window);
        deinitPipeline(pipeline);
    }
}