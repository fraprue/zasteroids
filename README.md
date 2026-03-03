# zasteroids
A personal learning project for Zig and basic game development, based on the 1979 Atari classic "Asteroids".

# Currently missing features
- Asteroids to split up when being hit with a projectile
- Peristent high score

# Currently known issues
- Collisions are too broad, i.e. they happen before objects visibly touch
- Turning off VSync doesn't seem to work on specific systems -> On Windows with NVidia GPU, turning off VSync via the Control Center seems to fix the issue
- High FPS (>100) causes stuttering -> Limiting the frame rate to 60 FPS seems to results in a smooth experience
