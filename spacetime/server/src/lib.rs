use spacetimedb::{Identity, ReducerContext, SpacetimeType, Table};


#[derive(SpacetimeType, Debug, Clone, Copy)]
pub struct DbVector3{
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[spacetimedb::table(name = player)]
pub struct Player {
    #[primary_key]
    identity: Identity,
    name: String,
    position: DbVector3,
    rotation: DbVector3,
}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    let _ = ctx;
    // Called when the module is initially published
}

#[spacetimedb::reducer(client_connected)]
pub fn identity_connected(ctx: &ReducerContext)  -> Result<(), String> {
    log::info!("Identity connected, {}!", ctx.sender);
    let _ = ctx.db.player().try_insert(Player{
        identity: ctx.sender,
        name: "Lucas".to_string(),
        position: DbVector3 { x: 0.0, y: 0.0, z: 0.0 },
        rotation: DbVector3 { x: 0.0, y: 0.0, z: 0.0 },
    });
    Ok(())
}

#[spacetimedb::reducer(client_disconnected)]
pub fn identity_disconnected(ctx: &ReducerContext) {
    if let Some(player) = ctx.db.player().identity().find(ctx.sender)
    {
        log::info!("Identity Disconnected, {}!", ctx.sender);
        ctx.db.player().delete(player);
    }
}

// #[spacetimedb::reducer]
// pub fn add(ctx: &ReducerContext, name: String) {
//     ctx.db.person().insert(Person { name });
// }

// #[spacetimedb::reducer]
// pub fn say_hello(ctx: &ReducerContext) {
//     for person in ctx.db.person().iter() {
//         log::info!("Hello, {}!", person.name);
//     }
//     log::info!("Hello, World!");
// }
