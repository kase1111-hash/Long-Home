# Long-Home: Complete Game Specification Sheet

## Executive Summary

**Title:** Long-Home (The Long Way Down)
**Genre:** Mountaineering Descent Simulation
**Core Thesis:** The game is about consequence, not conquest.

Players don't win by reaching the summit. They win by returning intact, having made good decisions before and after the summit. This framing differentiates it from 99% of mountain games.

**Design Philosophy:** A game about hubris vs humility, preparation vs improvisation, and the quiet cost of success.

---

## Table of Contents

1. [Core Game Loop](#1-core-game-loop)
2. [Difficulty System](#2-difficulty-system)
3. [Terrain & World Design](#3-terrain--world-design)
4. [Sliding Mechanics](#4-sliding-mechanics)
5. [Rope System](#5-rope-system)
6. [Time & Environmental Systems](#6-time--environmental-systems)
7. [Body Condition System](#7-body-condition-system)
8. [Risk & Feedback Systems](#8-risk--feedback-systems)
9. [Drone Camera System](#9-drone-camera-system)
10. [Camera Director AI](#10-camera-director-ai)
11. [Fatal Event Handling](#11-fatal-event-handling)
12. [Ethical Streaming Framework](#12-ethical-streaming-framework)
13. [User Interface Design](#13-user-interface-design)
14. [First-Time Player Experience](#14-first-time-player-experience)
15. [End States & Progression](#15-end-states--progression)
16. [Audio Design](#16-audio-design)
17. [Streaming & Replay System](#17-streaming--replay-system)
18. [Comparable Titles](#18-comparable-titles)

---

## 1. Core Game Loop

### Phase 1: Start State (Pre-Summit Conditions)

Players begin at the summit with difficulty locked in beforehand via trade-offs:

| Factor | Description |
|--------|-------------|
| **Time of Day** | Sun angle, shadows, freeze-thaw cycles |
| **Weather Window** | Stable, deteriorating, whiteout risk |
| **Gear Loadout** | Rope length, crampons, layers, emergency bivy |
| **Physical Condition** | Fatigue, hydration, minor injuries |
| **Knowledge** | Route beta, topo familiarity, previous ascent experience |

**Key Design Note:** These are trade-offs, not difficulty sliders. Every advantage costs weight, time, or stamina.

### Phase 2: Descent Planning (Low-Pressure, High Stakes)

Before moving, players:
- Study the topo map
- Choose descent line(s)
- Identify high-risk zones, slideable slopes, mandatory rope sections
- Assess escape options and time-to-dark thresholds

**Feel:** Calm but heavy—like chess before the clock starts.

### Phase 3: Descent Execution (Real-Time Tension)

Continuous time movement downhill where:
- Momentum matters
- Speed increases risk
- Slowing down increases exposure (cold, weather, darkness)

**Core Verbs:**
- Walk / Downclimb
- Controlled slide
- Arrest slide
- Rappel
- Traverse
- Rest (rare, dangerous if misused)

**Design Note:** Not about button mashing—it's about judgment under fatigue.

### Phase 4: Consequence Resolution

Mistakes accumulate rather than kill instantly:

| Mistake | Consequence |
|---------|-------------|
| Twisted ankle | Slower movement |
| Lost glove | Cold penalty later |
| Rope jam | Time loss |
| Small slide | Gear damage |

**The mountain remembers.**

### Phase 5: Survival Return

**Goal hierarchy:**
1. Finish alive
2. Finish intact
3. Finish with margin

Speed is secondary optimization, not primary win condition.

---

## 2. Difficulty System

### Philosophy: Function of Starting Conditions

Instead of Easy/Normal/Hard labels:

| Difficulty Type | Description |
|-----------------|-------------|
| **Environmental** | Weather, time of day, visibility |
| **Preparation** | Gear quality, loadout weight |
| **Knowledge** | Route familiarity, topo experience |

### Example Combinations:

| Conditions | Result |
|------------|--------|
| Clear weather + bad gear | Medium |
| Bad weather + good gear | Hard |
| Clear weather + light gear + fatigue | Deceptively lethal |

This mirrors real mountaineering psychology.

---

## 3. Terrain & World Design

### Real Mountains, Real Topo

**Data Sources:**
- Public-domain USGS topo maps
- DEM (digital elevation models)
- Real slope angles

**Terrain Generation Rules:**

| Factor | Determines |
|--------|------------|
| Steepness | Walkable vs downclimb vs slide vs rappel |
| Aspect | Ice formation, sun melt |
| Drainage logic | Creek formation in realistic gullies |
| Contour compression | Cliff formation thresholds |

**Key Principle:** You're not "painting terrain"—you're interpreting terrain.

### Terrain Is Read, Not Marked

- No glowing paths
- Players learn contour spacing interpretation
- "Safe-looking" terrain can lie
- Wide slopes can still be dangerous

**Result:** Educational gravity without tutorials.

---

## 4. Sliding Mechanics

### Design Pillars

1. **Sliding is never fully safe** - Even perfect slides carry residual risk
2. **Control is indirect** - Player influences, doesn't command
3. **Mountain decides outcome** - Skill shifts probabilities, not certainties
4. **Speed amplifies everything** - Both success and failure
5. **Trading time for margin** - Gain time, lose forgiveness

### Physical Model

**Preconditions for Sliding:**
- Slope angle within narrow band (~25-40° depending on surface)
- Surface cohesion supports controlled descent
- Player posture and speed compatible

**Sliding State Spectrum:**
```
Controlled descent → Marginal control → Accelerating instability → Loss of control
```

### Control Model

**Player Inputs Affect:**
- Weight shift (lean forward/back)
- Edge engagement (boots, heels)
- Surface interaction (hands, axe if equipped)
- Commitment (hesitation makes things worse)

**Inputs Do NOT:**
- Stop momentum instantly
- Override slope physics
- Guarantee recovery

### Entry & Exit

**Entry Point:**
- Brief posture shift
- Breath intake sound
- Friction release audio
- Creates tension: "Am I sure?"

**Exit Zones (Where slides are won or lost):**
- Visually subtle
- Slight slope reductions
- Texture changes
- Snow accumulation pockets
- No UI highlight

### Failure Taxonomy

| Failure Type | Result |
|--------------|--------|
| Minor Overrun | Extra distance, fatigue spike |
| Hard Stop | Tumble, injury chance |
| Compound Slide | Transition into steeper slope |
| Terminal Runout | No exit, death likely |

### Skill Curve

| Player Level | Experience |
|--------------|------------|
| **Early** | Chaotic, feels lucky, reactive slides |
| **Mid-Level** | Recognizes safe slope bands, begins planning |
| **Veteran** | Chains slides, uses terrain to scrub speed, only slides when exit guaranteed |

### Sliding Interactions

| System | Effect |
|--------|--------|
| Time | Saves daylight but increases fatigue/injury risk |
| Gear | Heavy pack = more momentum; Light pack = less forgiveness |
| Rescue | Dragging someone makes initiation harder, stopping much harder |

---

## 5. Rope System

### Philosophy: Strategic, Not Automatic

**Rope Characteristics:**
- Costs time to deploy
- Requires anchors (terrain-dependent)
- Reduces fall risk but increases exposure time

### Decision Framework

| Bad Decision | Consequence |
|--------------|-------------|
| Rope too early | Nightfall later |
| Rope too late | Terminal mistake |

**Sometimes:** Best move is no rope. Sometimes it's non-negotiable.

**Result:** Ropes feel like real tools, not abilities.

### UI Expression

- Physical rope coil in hands
- Weight visibly affects posture
- Anchors judged visually, not rated
- Slow animation, audio focus on knots
- No "100% safe" indicator

---

## 6. Time & Environmental Systems

### Time Scaling

**Example:** 1 real minute = 10 in-game minutes (adjustable per mountain scale)

### Time Affects:

| Factor | Impact |
|--------|--------|
| Light | Visibility, shadow interpretation |
| Temperature | Cold exposure, gear performance |
| Snow Condition | Surface stability, sliding safety |
| Weather | Roll probability changes |

### Environmental UI Expression

| Variable | How Shown |
|----------|-----------|
| Sun position | Shadows lengthen in real time |
| Temperature | Breath vapor, ice forming on rock |
| Weather | Clouds visibly thicken, wind audio |
| Time check | Pull out watch (takes time, requires stopping) |

---

## 7. Body Condition System

### Philosophy: Diegetic Feedback Only

The player's physical state is never represented by numbers or bars. All body condition information is conveyed through sensory feedback that a real mountaineer would experience.

### Core State Variables

| Variable | Range | Description |
|----------|-------|-------------|
| **Fatigue** | 0-1 | Overall physical exhaustion |
| **Cold Exposure** | 0-1 | Systemic cold accumulation |
| **Hydration** | 1-0 | Decreasing fluid levels |
| **Mental State** | 1-0 | Focus and decision-making clarity |
| **Injuries** | Array | Collection of active injuries |

### Fatigue System

**Fatigue Accumulation:**
- Increases with movement speed
- Increases with slope difficulty
- Increases with pack weight
- Increases when cold or injured
- Decreases slightly during rest (but rest has exposure costs)

**Fatigue Thresholds:**

| Level | Effect |
|-------|--------|
| 0.3 | Breathing audio changes |
| 0.5 | Movement slows, stability decreases |
| 0.7 | Input delay, camera sway |
| 0.9 | Critical - high fall risk |
| 1.0 | Collapse |

### Cold Exposure

**Heat Loss Factors:**
- Temperature delta (ambient vs body)
- Wind speed (major multiplier)
- Wet conditions (snow, sweat)
- Clothing insulation (subtracts from loss)

**Extremity Priority:**

| Body Part | Effect When Cold |
|-----------|-----------------|
| Hands | Dexterity loss, rope handling degraded |
| Feet | Stability loss, crampon effectiveness reduced |
| Core | Systemic performance loss, eventual hypothermia |

### Injury System

**Injury Types:**

| Type | Causes | Effects |
|------|--------|---------|
| Sprain | Falls, bad landings | Movement penalty, pain |
| Strain | Overexertion | Strength reduction |
| Laceration | Rock impact, gear | Bleeding, infection risk |
| Fracture | Major impacts | Severe movement penalty |
| Frostbite | Cold exposure | Permanent capability loss |

**Injury Severity Scale:**
- Minor (0.0-0.3): Manageable, affects performance slightly
- Moderate (0.3-0.6): Significant impact, requires adaptation
- Severe (0.6-0.9): Critical, may require rescue
- Critical (0.9-1.0): Life-threatening

### Self-Check Action

Players can stop to "check themselves," revealing their condition through descriptive messages:

**Example Messages:**
- "Legs burning. Pace unsustainable."
- "Fingers going numb. Need to keep moving."
- "Shoulder aches from the pack. Nothing serious."
- "Hands shaking. Cold or exhaustion?"
- "Vision narrowing. Rest or push through?"

**Cost:** Self-check takes time, during which:
- Cold exposure continues
- Weather may worsen
- Daylight depletes

### Capability Modifiers

Body state affects all actions through computed modifiers:

| Modifier | Affected By | Impacts |
|----------|-------------|---------|
| Movement | Fatigue, injuries, cold | Speed, stability |
| Stability | Fatigue, injuries, cold | Fall probability |
| Rope Handling | Hand cold, fatigue | Deployment time, jam chance |
| Slide Control | Fatigue, injuries | Control spectrum |
| Input Delay | High fatigue, mental state | Response time |
| Camera Sway | Fatigue, injuries | Visual stability |

---

## 8. Risk & Feedback Systems

### Risk Visibility System

**Not a HUD meter.** Instead:

**Subtle Cues:**
- Sound changes
- Camera shake
- Breathing rate
- Micro-slips

**Players feel risk before seeing it.** Avoids gamification while keeping fairness.

### Knowledge Progression (No XP)

Players don't "level up." They learn:
- Mountains descended before feel familiar
- Danger patterns recognized faster
- Route memory reduces planning time

**Knowledge is persistent, not stats.**

### Body Condition Expression

| System Variable | UI Expression |
|-----------------|---------------|
| Fatigue | Breathing audio, camera sway, delayed inputs |
| Cold exposure | Frost on screen edges, shivering animations |
| Hydration | Hand animation clumsiness |
| Injury | Localized effects |

**Explicit info only appears when player stops and "checks themselves."**

---

## 9. Drone Camera System

### Fictional Grounding

The drone is:
- Lightweight alpine recon drone
- Battery-limited
- Wind-limited
- Line-of-sight constrained
- Vulnerable to turbulence and cold

**Not a minimap replacement. Not omniscient.**

**Philosophy:** Shows how small you are, not how safe you are.

### Two Distinct Roles

#### A. Spectator/Streamer Drone (Non-Diegetic)

| Aspect | Description |
|--------|-------------|
| Purpose | Storytelling, audience comprehension, cinematic tension |
| Effect on Gameplay | None |
| Availability | Always in streamer/spectator mode |
| Feed | Parallel, not shared with player HUD |

Think: Documentary camera crew

#### B. Scout Drone (Diegetic, Easy Mode Only)

| Aspect | Description |
|--------|-------------|
| Purpose | Limited recon at a cost |
| Effect on Gameplay | Meaningful trade-offs |
| Characteristics | Optional, constrained, never perfectly reliable |

### Camera Language Rules

| Rule | Purpose |
|------|---------|
| Wide lenses only | No sniper zoom |
| Slight fisheye distortion | Authentic footage feel |
| Depth perception exaggerates steepness | Visual tension |
| Wind buffeting affects framing | Instability |
| Exposure struggles in snow + shadow | Realism |

### Information Restrictions

**The drone must NOT:**
- Highlight safe paths
- Color-code slope angles
- Reveal friction coefficients
- Identify slideable vs lethal snow
- Predict exits

**It shows shape, not truth.** Veterans still need judgment.

### Scout Drone Cost Structure

Using scout drone means:
- Time advances while scouting
- Weather may worsen
- Cold exposure continues
- Fatigue recovers slower

**Strategic pause, not free look.**

### Hard Mode Inversion

- Scout drone disabled
- Spectator drone sometimes loses player during major falls/slides
- Camera scrambles to reacquire
- Players can vanish into terrain

---

## 10. Camera Director AI

### Core Philosophy

A human filmmaker:
- Frames risk, not success
- Prioritizes context before action
- Reacts emotionally, not optimally
- Sometimes arrives late
- Sometimes pulls away instead of zooming in

**The drone AI must embody these flaws.**

### Three-Layer Architecture

| Layer | Function |
|-------|----------|
| **Situation Awareness** | "Something might happen" |
| **Directorial Intent** | "What kind of shot is appropriate?" |
| **Camera Behavior** | "How do I move and frame?" |

**The AI never thinks in coordinates—it thinks in shots.**

### Situation Awareness Signals

**Primary Signals (High Weight):**
- Sudden slope steepness increase
- Player speed change
- Sliding state entry
- Rope deployment
- Fatigue threshold crossed
- Loss of footing (micro-slip)
- Proximity to cliffs/runouts

**Secondary Signals (Mood Setters):**
- Weather shifts
- Light angle changes
- Isolation (no landmarks)
- Silence (wind drop)

### Shot Intent Types

#### A. Context Shot - "Show how small they are"
- Wide, static or slow drift
- High altitude, long duration
- **Triggers:** New terrain, major exposure, pre-slide hesitation

#### B. Tension Shot - "Stay close, don't interfere"
- Medium distance, slight handheld motion
- Parallel to movement, limited duration
- **Triggers:** Downclimbing, traversing, marginal slopes

#### C. Commitment Shot - "This is happening now"
- Lower altitude, forward-biased angle
- Accelerating movement, shorter focal length
- **Triggers:** Slide initiation, rope descent, sudden speed increase

#### D. Consequence Shot - "Let it play out"
- Hold framing longer than comfortable
- Minimal movement, no zoom-in, may lose subject
- **Triggers:** Falls, uncontrolled slides, injuries

#### E. Release Shot - "Breathe"
- Pull-back, rising altitude, longer horizon, calmer motion
- **Triggers:** Safe exit, reaching cabin, end of danger sequence

### Camera Movement Rules

| Rule | Purpose |
|------|---------|
| Acceleration/deceleration only | No instant direction changes |
| Wind influence increases with altitude | Authenticity |
| Obstacle avoidance is late | Human pilot feeling |
| Player offset from center | Rule of thirds |
| Sometimes partially occluded | Imperfection |

### Anticipation vs Reaction

**The drone:**
- Moves before slide starts
- Drifts toward exit zones
- Hovers slightly uphill before danger

**But it:**
- Does not reposition instantly
- Sometimes commits to wrong angle
- Must recover like a human would

**Great shots are earned, not guaranteed.**

### Mistakes Are Features

The AI occasionally:
- Frames too wide
- Loses subject in whiteout
- Arrives late to a fall

**Viewers forgive imperfection. They distrust perfection.**

### Emotional Rhythm Engine

The AI tracks pacing:
- After intense sequence → forced calm shot
- After long calm → seeks tension
- Avoids rapid shot changes

Creates filmic arc over full descent.

### Streamer Controls

**Streamers CAN:**
- Bias shot intent (context-heavy vs action-heavy)
- Lock shot type temporarily
- Increase "human error" slider

**Streamers CANNOT:**
- Force angles
- Teleport drone
- Override safety limits

**Collaboration with AI, not puppeteering.**

### The One Rule

**The drone never steals focus from the mountain.** If the shot shows off the player more than the terrain, it's wrong.

---

## 11. Fatal Event Handling

### Core Principle

> "The camera does not look away—but it does not exploit."

- The drone never confirms death
- It only records loss of control
- Death is inferred by absence of recovery

### Phase-Based Response

#### Phase 1: Moment of Error
- AI hesitates, micro-delay
- Slight framing error (human shock)
- Medium-wide shot, player not centered
- Terrain dominates frame

#### Phase 2: Loss of Control
- No zoom-in, no frantic chase
- Drone chooses scale over proximity
- Lateral tracking or static wide
- Camera drifts upward, not downward
- Message: "This is bigger than them now"

#### Phase 3: The Vanishing
- Drone does not follow into abyss
- Slows, loses subject behind terrain
- Wind noise overtakes motor
- Framing: empty slope, moving snow, no body

#### Phase 4: Aftermath
- Drone holds position
- No music, no motion for several seconds
- Wind continues, snow settles
- **This is one of the most important moments in the game**

#### Phase 5: Acknowledgment
- Drone slowly ascends, pulls back
- Reveals terrain enormity
- No text, no marker, no body
- **The mountain remains**

### Fatal Slide Specific Rules

| Phase | Behavior |
|-------|----------|
| Early slide | Drone tracks laterally |
| Speed escalates | Drone pulls away, not closer |
| Terminal | Drone loses subject naturally (terrain break) |

**Watching someone disappear is more powerful than watching them impact.**

### Prohibited Behaviors

**The drone must NEVER:**
- Zoom in on impact
- Follow into unseen voids
- Reframe to show body clearly
- Circle a stopped body
- Hover directly overhead

**No autopsy shots. No spectacle. No triumph of the camera.**

### Replay Rules

- Fatal moments replayed once at normal speed
- No slow-motion
- No camera switching
- One continuous take
- Then replay defaults to path, not fall

---

## 12. Ethical Streaming Framework

### North Star

> "Witness without harm."

The game must never surprise viewers with graphic content, but must never lie about risk.

**Not hiding death—preventing ambush.**

### Core Principles

1. Forewarning without spoilers
2. Player choice, not platform enforcement
3. Respectful abstraction over explicit depiction
4. Consistency—never tone-police only sometimes
5. Silence and distance instead of dramatization

### Content Warnings

#### Stream Start Overlay (Optional, Default ON)
> "This game depicts realistic mountaineering risk, including injury and death."

No flashing, no icons, no voiceover. Can be disabled with confirmation.

#### Contextual Risk Warnings
Triggered when entering terminal terrain, extreme weather, fatigue-critical states.

Displayed as brief, neutral caption in spectator UI only:
> "Risk exposure increasing."

No mention of death. No drama.

### Predictive Fades

When system detects irreversible loss of control, stream feed (not player feed) withdraws.

**Process:**
1. Drone pulls back
2. Exposure lowers slightly
3. Audio compresses
4. Motion slows
5. If death occurs: drone loses subject naturally
6. Image holds on environment
7. Fade to black after absence is clear

**Fade happens only after viewer understands something went wrong.**

### Streamer Mode Options

| Option | Default |
|--------|---------|
| Enable Predictive Fades | ON |
| Replace fatal audio with wind-only | Available |
| Delay fatal replays until stream end | Available |
| Show static warning banner | Available |
| Force explicit camera behavior | NOT AVAILABLE |

**Can reduce intensity—cannot increase it.**

### Viewer Experience During Fatal Events

- No death text
- No skull icons
- No "You Died" equivalent
- Chat not paused
- Stream not interrupted

**The game trusts the audience to understand.**

### Replay & Highlight Ethics

- Fatal moments excluded from auto-highlights
- Game-generated clips stop before loss of control, resume after fade
- Highlight titles never reference death

**Example:** "Upper Face Descent – Weather Turn" not "Brutal Fall"

### Platform Safety

System organically exceeds Twitch/YouTube requirements:
- No gore
- No lingering on bodies
- No shock framing

**Position:** Realistic risk, responsibly handled.

---

## 13. User Interface Design

### UI North Star

> "The player should feel like they are reading the mountain, not a dashboard."

If information cannot plausibly be perceived by a tired mountaineer in bad conditions, it shouldn't be shown explicitly.

### Core Design Rules

1. **Diegetic first, abstract last**
2. **Body signals > environmental cues > minimal overlays**
3. **Information degrades with fatigue, weather, stress**
4. **No constant HUD** - UI appears only when invoked or triggered by risk
5. **Everything has cognitive cost** - Checking info takes time, attention, stability

### System-to-UI Mapping

#### Health/Body Condition
- Breathing audio changes
- Camera sway under fatigue
- Hand animations become clumsier
- Delayed input responses
- Frost on screen edges

**Explicit info only when player stops to "check themselves"**

#### Risk Level
- Footstep sound texture changes
- Micro-slips (visual + audio)
- Camera tilt increases
- Controller vibration mimics instability
- Peripheral blur in high-risk zones

#### Navigation & Topo
- Player physically unfolds map
- Wind can obscure it
- Hands shake in fatigue/wind
- No "you are here" dot by default
- Location estimated via landmarks, elevation, memory

#### Sliding
- "Test" slope with foot
- Snow displacement visual
- Audio pitch indicates firmness
- Camera lowers during slide
- Exit zones: terrain cues only, no UI warnings

### Minimal Abstract UI

Allowed only when absolutely necessary:
- Small icon for mandatory rope or severe cold
- Appears briefly, fades quickly
- Never persistent

**Sanity Check:** "Would a tired climber notice this—or only a gamer?"

### Accessibility

Options exist but are opt-in:
- Optional subtle slope shading
- Clearer slideable terrain textures
- Reduced camera sway

**Default experience remains uncompromised.**

---

## 14. First-Time Player Experience

### Design Goal

**Teach:**
- Movement caution
- Camera awareness
- Spatial danger
- Game is not fair
- Consequences are immediate and permanent

**Without:**
- UI popups
- Button prompts
- Text boxes
- Safe rails

### Opening: The Knife Edge

**Spawn State:**
- Player spawns standing on narrow summit ridge
- Steep drops on both sides
- Wind audible before visuals resolve
- Camera fades in slowly, swaying

**Instructor (Diegetic Voice):**
> "Alright. Take a breath. You're standing where people usually stop thinking."
> "Look around—slowly. And don't back up."

**If player backs up:** Immediate slip, short fall, fade out, reload with no commentary.

**Lesson:** The world is live from second one.

### Silent Teaching Methods

| What's Taught | How |
|---------------|-----|
| Camera destabilizes you | Narrow ridge discovery |
| Body orientation matters | Natural movement experimentation |
| Standing still costs focus | Micro-slips on careless movement |
| Terrain reading | Instructor gestures at shapes, not paths |
| Time pressure | Clouds, wind pickup, "We've got light. Not a lot." |
| Sliding | Instructor demonstrates, then "Your call" |
| Rope cost | Long animation, "That'll cost us daylight" |

### Hard Mode Variant

Same opening, but:
- Instructor slips, rope snaps free
- Disappears downslope
- Just: scream, silence, distant sliding shape
- No cutscene, no dramatic music

**Player must:**
- Overcome shock
- Find cabin
- Discover rescue sled
- Return for instructor

**Teaching:** Other lives make everything harder.

---

## 15. End States & Progression

### Failure Philosophy

Deaths shouldn't feel random. They should feel:
> "I knew better."

**Post-Run:**
- Show replay on topo
- Highlight where decisions compounded
- No blame, just clarity

**Makes failure addictive instead of frustrating.**

### End State Types

| Outcome | Classification |
|---------|----------------|
| Clean return | Success |
| Injured return | Qualified success |
| Forced bivy | Survival |
| Rescue | Near-failure |
| Fatality | Failure |

**Some "losses" are still meaningful completions.**

### Post-Run UI

**Topo Replay:**
- Path drawn slowly
- Key moments highlighted: slide starts, rope placements, fatigue thresholds
- Minimal text: "You were moving fast when you needed margin."

**No score screen. No medals.**

---

## 16. Audio Design

### Emotional Tone

- No bombastic music
- Let players sit with their thoughts
- This is a return, not a victory lap

### Soundscape Elements

| Sound | Purpose |
|-------|---------|
| Wind | Constant environmental presence |
| Crampon scrape | Movement feedback |
| Rope tension | Mechanical feedback |
| Breathing | Player state indicator |
| Silence | Tension tool |

### Drone Audio

| Context | Audio Behavior |
|---------|----------------|
| Tension shots | Loud motors |
| Wide shots | Nearly silent |
| Loss of control | Sudden audio drop |
| Aftermath | Only wind, occasional ice |

### Fatal Event Audio

**During Loss:**
- Wind drowns out motor
- Player audio cuts abruptly (not fade)
- Drone motor stabilizes, almost calm

**After Vanish:**
- Only wind
- Occasional ice movement
- No score, no sting

**Silence is respect.**

---

## 17. Streaming & Replay System

### Recording System

The game continuously records run data for post-game analysis and replay.

**Recorded Data:**

| Data Type | Frequency | Purpose |
|-----------|-----------|---------|
| Player State | 30 fps | Position, velocity, movement state |
| Camera State | 30 fps | Drone position, shot intent |
| Events | On occurrence | Slides, falls, rope deployments, decisions |
| Audio State | Snapshots | For reconstruction |
| Weather State | On change | Environmental context |

### Compression Strategy

- Delta compression for continuous position data
- Keyframes every 5 seconds
- Event-based recording for discrete state changes
- Efficient storage format for long descents

### Replay Playback

**Features:**

| Feature | Normal Runs | Fatal Runs |
|---------|-------------|------------|
| Speed control | Full range | Normal speed only |
| Camera angles | Selectable | Fixed (ethical constraint) |
| Topo overlay | Available | Available |
| Moment highlighting | All moments | Pre-loss only |

**Topo Replay Visualization:**
- Path drawn slowly on topographic map
- Key moments highlighted with icons
- Decision points marked
- Slide entries/exits shown
- Fatigue thresholds indicated
- Minimal text insights (not judgmental)

### OBS Integration

**Supported Features:**

| Feature | Description |
|---------|-------------|
| Scene Switching | Auto-switch between gameplay and drone view |
| Source Visibility | Toggle HUD elements for stream |
| Custom Overlays | Streamer information panels |
| Event Triggers | Auto-highlight on key moments |
| Chat Integration | Optional viewer interaction |

### Streamer Tools

**Available Controls:**

| Control | Effect |
|---------|--------|
| Shot Intent Bias | Prefer wide vs close shots |
| Human Error Slider | Increase/decrease camera imperfection |
| Shot Lock Toggle | Hold current shot type |
| Warning Overlay | Show/hide content warnings |
| Delayed Replay | Queue fatal replays for stream end |

**Unavailable Controls (Ethical Constraints):**
- Force specific camera angles
- Teleport drone
- Override safety limits
- Zoom during fatal events
- Slow-motion on deaths

### Highlight Generation

**Auto-Highlight Criteria:**
- Successful long slides
- Close calls with recovery
- Rope deployments in difficult terrain
- Weather transitions
- Safe arrivals after danger

**Excluded from Auto-Highlights:**
- Fatal moments
- Uncontrolled slides
- Impact events

**Highlight Naming Convention:**
- "Upper Face Descent – Weather Turn" (not "Brutal Fall")
- "Ridge Traverse – Wind Challenge" (not "Near Death")
- Focus on terrain and conditions, not drama

### Speedrun Timer

**Optional Display:**
- Real-time elapsed
- Game-time elapsed
- Segment splits (by terrain section)
- Personal best comparison
- No leaderboard pressure (personal tracking only)

---

## 18. Comparable Titles

| Title | Comparison Point |
|-------|------------------|
| Journey | Emotional pacing |
| Death Stranding | Terrain respect |
| The Long Dark | Environment as antagonist |
| Real mountaineering accident reports | Source material |

**Differentiator:** None of these focus on descent psychology.

---

## Appendix: Key Design Mantras

1. "The game is about consequence, not conquest."
2. "The player should feel like they are reading the mountain, not a dashboard."
3. "The drone never steals focus from the mountain."
4. "The camera does not look away—but it does not exploit."
5. "Witness without harm."
6. "The drone records the truth, but it does not sensationalize it."
7. "The drone can never save you—only show how close you came."
8. "Silence is respect."
9. "Were you ready to come back?"
10. "This camera is a witness, not a spectacle."

---

*Specification compiled from project documentation. Version 1.1*
