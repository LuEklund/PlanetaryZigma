use spacetimedb::SpacetimeType;

#[derive(SpacetimeType, Debug, Clone, Copy)]
pub struct DbVector3{
    pub x: f32,
    pub y: f32,
    pub z: f32,
}


impl std::ops::Add<&DbVector3> for DbVector3 {
    type Output = DbVector3;

    fn add(self, other: &DbVector3) -> DbVector3 {
        DbVector3 {
            x: self.x + other.x,
            y: self.y + other.y,
            z: self.z + other.z,
        }
    }
}

impl std::ops::Add<DbVector3> for DbVector3 {
    type Output = DbVector3;

    fn add(self, other: DbVector3) -> DbVector3 {
        DbVector3 {
            x: self.x + other.x,
            y: self.y + other.y,
            z: self.z + other.z,
        }
    }
}

impl std::ops::AddAssign<DbVector3> for DbVector3 {
    fn add_assign(&mut self, rhs: DbVector3) {
        self.x += rhs.x;
        self.y += rhs.y;
        self.z += rhs.z;
    }
}

impl std::iter::Sum<DbVector3> for DbVector3 {
    fn sum<I: Iterator<Item = DbVector3>>(iter: I) -> Self {
        let mut r = DbVector3::new(0.0, 0.0, 0.0);
        for val in iter {
            r += val;
        }
        r
    }
}

impl std::ops::Sub<&DbVector3> for DbVector3 {
    type Output = DbVector3;

    fn sub(self, other: &DbVector3) -> DbVector3 {
        DbVector3 {
            x: self.x - other.x,
            y: self.y - other.y,
            z: self.z - other.z,
        }
    }
}

impl std::ops::Sub<DbVector3> for DbVector3 {
    type Output = DbVector3;

    fn sub(self, other: DbVector3) -> DbVector3 {
        DbVector3 {
            x: self.x - other.x,
            y: self.y - other.y,
            z: self.z - other.z,
        }
    }
}

impl std::ops::SubAssign<DbVector3> for DbVector3 {
    fn sub_assign(&mut self, rhs: DbVector3) {
        self.x -= rhs.x;
        self.y -= rhs.y;
        self.z -= rhs.z;
    }
}

impl std::ops::Mul<f32> for DbVector3 {
    type Output = DbVector3;

    fn mul(self, other: f32) -> DbVector3 {
        DbVector3 {
            x: self.x * other,
            y: self.y * other,
            z: self.z * other,
        }
    }
}

impl std::ops::Div<f32> for DbVector3 {
    type Output = DbVector3;

    fn div(self, other: f32) -> DbVector3 {
        if other != 0.0 {
            DbVector3 {
                x: self.x / other,
                y: self.y / other,
                z: self.z / other,
            }
        } else {
            DbVector3 { x: 0.0, y: 0.0, z: 0.0 }
        }
    }
}

impl DbVector3 {
    pub fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    pub fn sqr_magnitude(&self) -> f32 {
        self.x * self.x + self.y * self.y + self.z * self.z 
    }

    pub fn magnitude(&self) -> f32 {
        (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }

    pub fn normalized(self) -> DbVector3 {
        self / self.magnitude()
    }
}