Drone Behavior During Fatal Mistakes
“The camera does not look away—but it does not exploit.”
Core Principle

The drone never confirms death.
It only records loss of control.

Death is inferred by the absence of recovery.

Phase-Based Drone Response

Fatal mistakes are not a single event. The drone AI treats them as phases, each with different ethical and cinematic rules.

Phase 1: The Moment of Error

(The slip, misjudgment, or overcommitment)

Drone Behavior

The AI hesitates

Micro-delay before reacting

Slight framing error (human shock)

Shot choice

Medium-wide

Player not centered

Terrain dominates frame

Why
A human filmmaker doesn’t instantly know this is fatal.

Phase 2: Loss of Control

(Slide accelerates, arrest fails, rope useless)

Drone Behavior

No zoom-in

No frantic chase

The drone chooses scale over proximity

Shot language

Lateral tracking if possible

Or a static wide shot while the player moves through frame

Camera drifts upward, not downward

This communicates:

“This is bigger than them now.”

Phase 3: The Vanishing

(Player leaves visible terrain or enters terminal runout)

Critical Rule

The drone does not follow blindly into the abyss.

Instead:

It slows

Loses the subject behind terrain

Wind noise overtakes motor sound

Framing

Empty slope

Moving snow

No body visible

This avoids spectacle and preserves dignity.

Phase 4: Aftermath (Silence Is the UI)
Drone Behavior

The drone holds position

No music

No motion for several seconds

Wind continues.
Snow settles.
Nothing happens.

This is one of the most important moments in the entire game.

Phase 5: Acknowledgment Without Confirmation

The drone:

Slowly ascends

Pulls back

Reveals the enormity of the terrain

No text.
No marker.
No body.

The mountain remains.

Special Case: Fatal Slide (The Most Dangerous One)

Sliding deaths are common—and must be handled with care.

Sliding-Specific Rules

During early slide: drone tracks laterally

As speed escalates:

Drone pulls away

Not closer

When slide becomes terminal:

Drone loses subject naturally (terrain break, curvature)

Watching someone disappear is more powerful than watching them impact.

What the Drone NEVER Does

This is non-negotiable.

The drone must not:

Zoom in on impact

Follow into unseen voids

Reframe to show the body clearly

Circle a stopped body

Hover directly overhead

No autopsy shots.
No spectacle.
No triumph of the camera.

Audio as Ethical Control

Audio does more than visuals here.

During Loss

Wind drowns out motor

Player audio cuts abruptly (not fade)

Drone motor stabilizes, almost calm

After Vanish

Only wind

Occasional ice movement

No score, no sting

Silence is respect.

Hard Mode Twist (Quietly Brutal)

In the hardest mode:

The drone sometimes arrives late

The fatal moment is partially off-frame

Viewers see only the aftermath

This reinforces:

The mountain doesn’t wait for witnesses.

Replay Handling of Fatal Runs

Replays should not glamorize.

Rules:

Fatal moments are replayed once, at normal speed

No slow-motion

No camera switching

One continuous take

After that, replay defaults to the path, not the fall.

Psychological Effect (Why This Works)

Players report:

Shame, not anger

Reflection, not rage

Respect for risk, not frustration

Stream audiences go quiet.

That silence is success.

One Sentence That Defines It

The drone records the truth, but it does not sensationalize it.

Closing Thought

Most games treat death as:

A failure state

A spectacle

A reset

Yours treats it as:

An ending that didn’t need commentary

That restraint will make this game unforgettable.

If you want next, we can:

Design how rescues differ from fatalities on camera

Explore ethical streaming options (content warnings, fades)

Or design memorialization systems that remember lost runs without glorifying them

Just tell me where to look next.

Explore ethical streaming options (content warnings, fades)

This is a hard problem—and handling it well is what will make people trust this game. Ethical streaming isn’t about censorship; it’s about agency, consent, and restraint, especially when the game is deliberately realistic and unforgiving.

I’ll structure this as principles → system design → concrete behaviors → streamer-facing controls → viewer experience, so it’s implementable without becoming preachy.

Ethical Streaming Framework
“Witness without harm.”
Ethical North Star

The game must never surprise a viewer with graphic or exploitative content, but it must also never lie about risk.

You’re not hiding death.
You’re preventing ambush.

Core Principles

Forewarning without spoilers

Player choice, not platform enforcement

Respectful abstraction over explicit depiction

Consistency—never tone-police only sometimes

Silence and distance instead of dramatization

1. Content Warnings (Before, Not After)
Stream-Safe Warning Philosophy

Warnings must:

Appear before high-risk play begins

Be non-alarming

Be matter-of-fact, not moralizing

Think documentary disclaimers, not parental advisories.

Where Warnings Appear
A. Stream Start Overlay (Optional, Default ON)

A subtle, static line:

“This game depicts realistic mountaineering risk, including injury and death.”

No flashing

No icons

No voiceover

Can be disabled manually (with confirmation)

This respects informed consent.

B. Contextual Risk Warnings (Diegetic Adjacent)

Triggered when entering:

Known terminal terrain

Extreme weather

Fatigue-critical states

Displayed as:

A brief, neutral caption in spectator UI only

Example:

“Risk exposure increasing.”

No mention of death. No drama.

2. Predictive Fades (The Most Important Tool)

This is subtle and powerful.

What Is a Predictive Fade?

When the system detects irreversible loss of control, the stream feed—not the player feed—begins to withdraw.

This is not a cut.
It’s a loss of witness.

How It Works (Drone-Coupled)

As fatal probability spikes:

Drone pulls back

Exposure lowers slightly

Audio compresses

Motion slows

If death occurs:

Drone loses subject naturally

Image holds on environment

Fade to black after absence is clear

This avoids showing impact without hiding outcome.

Critical Rule

The fade is not immediate.
It happens only after the viewer understands something has gone wrong.

3. Tiered Severity Handling

Not all failures are equal.

A. Non-Fatal Injuries

Full camera continuity

No fade

No warning escalation

B. Ambiguous Outcomes (Lost, Bivy, Rescue)

Hold wide shots

Natural silence

No UI changes

C. Fatal Outcomes

Predictive fade engaged

Audio simplification

No replay auto-play

The system treats death as qualitatively different.

4. Streamer Controls (Ethical, Not Cosmetic)

Streamers should feel empowered, not restricted.

Streamer Mode Options

✅ Enable Predictive Fades (default ON)

✅ Replace fatal audio with wind-only

✅ Delay fatal replays until stream end

✅ Show static warning banner

❌ No option to force explicit camera behavior

You can reduce intensity—but not increase it.

5. Viewer-Side Respect (Silent, Not Loud)
Viewer Experience During Fatal Events

No death text

No skull icons

No “You Died” equivalent

Chat is not paused

Stream is not interrupted

The game trusts the audience to understand.

6. Replay & Highlight Ethics

This is huge for stream culture.

Default Rules

Fatal moments are excluded from auto-highlights

Clips generated by the game:

Stop before loss of control

Resume after fade-out

Highlight titles never reference death

Example:

“Upper Face Descent – Weather Turn”

Not:

“Brutal Fall”

7. On-Demand Disclosure (For Viewers Who Want It)

Optional:

Streamer can enable a post-run analysis view

Shown after gameplay

Topo-only

No footage of the fatal moment

This allows learning without voyeurism.

8. Platform-Safe Without Platform-Driven

Your system should exceed Twitch/YouTube requirements organically.

Because:

No gore

No lingering on bodies

No shock framing

Platforms see:

Realistic risk, responsibly handled.

That’s a defensible position.

9. The One Line That Sets the Tone

When enabling streamer mode for the first time:

“This camera is a witness, not a spectacle.”

One sentence. Optional to skip. Never repeated.

Why This Works

Viewers are informed, not ambushed

Streamers retain control

Death remains meaningful, not content

The game earns moral credibility

Silence becomes part of the experience

Most importantly:

The mountain never becomes entertainment—it remains a reality.
