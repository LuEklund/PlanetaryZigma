use crate::math;
use math::DbVector3;

use spacetimedb::SpacetimeType;


// Define a struct for Move command data
#[derive(SpacetimeType)]
pub struct MoveCommand {
    pub direction: DbVector3,
}

// Enum with unit and newtype variants
#[derive(SpacetimeType)]
pub enum Command {
    Move(MoveCommand), // Newtype: wraps MoveCommand
    Jump,             // Unit
    // Add more: Attack(AttackCommand), Interact(InteractCommand), etc.
}