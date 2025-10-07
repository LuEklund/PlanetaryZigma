use std::time::Duration;
pub mod math;
pub mod command;

use math::DbVector3;
use command::Command;
use spacetimedb::{Identity, ReducerContext, ScheduleAt, SpacetimeType, Table};



#[spacetimedb::table(name = player, public)]
pub struct Player {
    #[primary_key]
    identity: Identity,
    #[auto_inc]
    player_id: u32,
    name: String,
    position: DbVector3,
    rotation: DbVector3,
    direction: DbVector3,
}

#[spacetimedb::table(name = move_all_players_timer, scheduled(move_all_players))]
pub struct MoveAllPlayersTimer {
    #[primary_key]
    #[auto_inc]
    scheduled_id: u64,
    scheduled_at: spacetimedb::ScheduleAt,
}


// Reducer: Handle all commands
#[spacetimedb::reducer]
pub fn player_command(ctx: &ReducerContext, cmd: Command) -> Result<(), String> {
    let mut player = ctx.db.player().identity().find(&ctx.sender).unwrap();
    match cmd {
        Command::Move(move_cmd) => {
            let dir_mag = move_cmd.direction.magnitude();
            if dir_mag < 0.01 || dir_mag > 1.1 {
                return Err("Invalid direction magnitude".to_string());
            }
            player.direction = move_cmd.direction.normalized();
            ctx.db.player().identity().update(player);
        }
        Command::Jump => {
        }
    }
    Ok(())
}

#[spacetimedb::reducer]
pub fn move_all_players(ctx: &ReducerContext, _timer: MoveAllPlayersTimer) -> Result<(), String> {

    // Handle player input
    for player_itr in ctx.db.player().iter() {

        let player = ctx.db.player().identity().find(player_itr.identity);
        let mut player = player.unwrap();

        let direction = player.direction * 0.5;
        let new_pos = player.position + direction;

        player.position = new_pos;
        player.direction = DbVector3 { x: 0.0, y: 0.0, z: 0.0 };

        ctx.db.player().identity().update(player);
    }



    Ok(())
}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) -> Result<(), String>{
    ctx.db
    .move_all_players_timer()
    .try_insert(MoveAllPlayersTimer {
        scheduled_id: 0,
        scheduled_at: ScheduleAt::Interval(Duration::from_millis(50).into()),
    })?;
    Ok(())
}



#[spacetimedb::reducer(client_connected)]
pub fn identity_connected(ctx: &ReducerContext)  -> Result<(), String> {
    log::info!("Identity connected, {}!", ctx.sender);
    if let Some(player) = ctx.db.player().identity().find(ctx.sender)
    {
        log::info!("Player FOUND", );

       _ = player;
    }
    else {
        log::info!("+ Player INSERT", );
        let _ = ctx.db.player().insert(Player{
        identity: ctx.sender,
        player_id: 0,
        name: "Lucas".to_string(),
        position: DbVector3 { x: 0.0, y: 0.0, z: 0.0 },
        rotation: DbVector3 { x: 0.0, y: 0.0, z: 0.0 },
        direction: DbVector3 { x: 0.0, y: 0.0, z: 0.0 },
});
    }
    log::info!("Player tot: , {}!", ctx.db.player().count());
    Ok(())

}

#[spacetimedb::reducer(client_disconnected)]
pub fn identity_disconnected(ctx: &ReducerContext) {
    if let Some(player) = ctx.db.player().identity().find(ctx.sender)
    {
        log::info!("Identity Disconnected, {}!", ctx.sender);
        ctx.db.player().delete(player);
        log::info!("Player tot: , {}!", ctx.db.player().count());
    }
}

