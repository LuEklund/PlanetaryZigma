fn main() {
    // Tell Cargo/rustc: look in the current project directory for libs
    println!("cargo:rustc-link-search=native=.");

    // Link against "render" (librender.so / render.dll / librender.dylib)
    println!("cargo:rustc-link-lib=render");


    // Embed an rpath so the executable looks for .so files next to it at runtime
    println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN/../..");

    // Also link system deps Zig used
    #[cfg(target_os = "linux")]
    {
        println!("cargo:rustc-link-lib=glfw");
        println!("cargo:rustc-link-lib=GL");
    }

    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=glfw");
        println!("cargo:rustc-link-lib=framework=OpenGL");
    }

    #[cfg(target_os = "windows")]
    {
        println!("cargo:rustc-link-lib=glfw3");
        println!("cargo:rustc-link-lib=opengl32");
    }
}
