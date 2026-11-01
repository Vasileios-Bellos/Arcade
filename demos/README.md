# Arcade - Demos

Standalone MATLAB examples of graphics layering, callback functions, display scaling, and animation, adapted from [Arcade](https://github.com/Vasileios-Bellos/Arcade).

The accompanying [article on making games in MATLAB](https://github.com/Vasileios-Bellos/Arcade/blob/master/dev/article/README.md) explains the techniques used in these examples.

Both demos require only base MATLAB. Each function is self-contained and opens its own figure.

---

## Running the Demos

If you downloaded the source, add this folder to the MATLAB path. Toolbox installation adds it automatically. Run either function from the Command Window.

| Function | Demonstrates |
|----------|--------------|
| [arcadeBallDemo](arcadeBallDemo.m) | Layered graphics, mouse input, display scaling, and movement based on elapsed time |
| [arcadeEffectsDemo](arcadeEffectsDemo.m) | Expanding rings and rays, with automatic playback or overlapping effects triggered by mouse clicks |

---

## Ball Animation

```matlab
arcadeBallDemo
```

The ball moves around the playfield until you close the figure.

| Action | Response |
|--------|----------|
| Click inside the figure | Reverse the ball's vertical direction on each press |
| Resize the window | Scale the scene while preserving the playfield's aspect ratio |
| Close the figure | Stop the animation |

The ball uses Pong's layered appearance: a colored dot, a translucent glow, and a white center. All three graphics objects are created once, then their positions are updated together. Resizing scales marker sizes, text, and line widths linearly; the glow's marker area scales with the square of that factor. The ball's center reaches each playfield edge before reflecting, extending Pong's top and bottom wall-contact rule to all four edges.

### Optional Arguments

```matlab
arcadeBallDemo(Inf, 0.04)   % Run until closed, with a longer pause between updates.
arcadeBallDemo(30)          % Run for up to 30 seconds, or until closed.
```

| Argument | Default | Description |
|----------|---------|-------------|
| `durationSeconds` | `Inf` | Positive duration in seconds; `Inf` runs until the figure closes |
| `pauseSeconds` | `0.02` | Finite, nonnegative pause requested between updates, in seconds |

Movement uses measured elapsed time and a reference frequency of 60 updates per second. Changing the pause adjusts the animation's pacing; the actual frame rate also depends on the time spent updating and drawing the scene. Each update represents at most 0.1 seconds of elapsed time, limiting the displacement after a long delay.

---

## Animated Impact Effect

```matlab
arcadeEffectsDemo
```

Click inside the playfield to create a burst at the mouse position. A ring and eight rays expand, narrow, and fade. Each burst runs independently, allowing several to overlap. The default lifetime is 0.9 seconds, making the expansion and fade easier to see. Resize the window to scale the scene, and close it to stop.

The ring and rays follow Arcade's shared hit effect, used in Flick It! Their line objects are created at the start of a burst, updated throughout its lifetime, and deleted when that burst ends. Normalized progress controls the expansion and fade, so changing the lifetime stretches the same animation over a different duration.

For automatic playback:

```matlab
arcadeEffectsDemo(Mode="automatic")
```

Automatic mode repeats the effect at the center, with a short gap between bursts.

### Optional Arguments

```matlab
arcadeEffectsDemo(0.3)       % Match Arcade's nominal impact duration.
arcadeEffectsDemo(0.9, 6)    % Allow six mouse-triggered bursts.
arcadeEffectsDemo(0.9, 6, Mode="automatic")   % Play six bursts automatically.
```

| Argument | Default | Description |
|----------|---------|-------------|
| `lifetimeSeconds` | `0.9` | Positive, finite nominal lifetime of each burst, in seconds |
| `repetitions` | `Inf` | Positive integer limit on the number of bursts, or `Inf` to continue until the figure closes |
| `Mode` | `"manual"` | `"manual"` creates a burst at the mouse position on each click; `"automatic"` repeats bursts at the center |

With a finite repetition count, the figure closes automatically after the final burst. In manual mode, the count limits the number of bursts you can create; all active bursts finish before the figure closes.

---

## Function Help

The opening comments in each function describe its controls and arguments. To read them in the Command Window:

```matlab
help arcadeBallDemo
help arcadeEffectsDemo
```
