# zasteroids
A personal learning project for Zig and basic game development, based on the 1979 Atari classic "Asteroids".

You are the colorful triangle in the middle of the screen. You can move with the WASD keys and shoot with Spacebar.
Alternatively, you can play with a gamepad. Left Stick moves the ship and right stick rotates it. You can shoot using the right bumper.

# Features
- [x] GPU-based rendering of game objects
- [x] Basic UI
- [x] Keyboard + Mouse support
- [x] Gamepad support
- [x] Basic Sound effects + music
- [x] Scoring system, incl. persistent highscores
- [x] Asteroids splitting up on being hit
- [x] Extensive configuration options
- [x] Persistent configuration
- [x] CPU + Memory profiling tools
- [ ] Configuration of key bindings
- [ ] Local Multiplayer

# Currently known issues
- Collisions are too broad, i.e. they happen before objects visibly touch
- Turning off VSync doesn't seem to work on specific systems -> On Windows with NVidia GPU, turning off VSync via the Control Center seems to fix the issue. Doesn't reproduce on Steam Deck.
- High FPS (>100) causes stuttering -> Limiting the frame rate to 60 FPS seems to results in a smooth experience

# Profiling
To profile the running executable, simply build it with `-Denable_ztracy=true`.
Then start a [compatible Tracy client](https://github.com/wolfpld/tracy/releases/tag/v0.13.1), start the game and connect the Tracy client to the running game.
You should then see a breakdown of function calls, CPU and RAM usage.
