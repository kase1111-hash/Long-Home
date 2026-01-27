# Software Audit Report: Long-Home

**Audit Date:** 2026-01-27
**Auditor:** Claude (Opus 4.5)
**Version Audited:** 0.1.0-alpha
**Codebase Size:** ~111 GDScript files, ~46,254 lines of code

---

## Executive Summary

Long-Home is a well-architected Godot 4.2 mountaineering descent simulation game with sophisticated systems for movement, terrain, weather, and cinematography. The codebase demonstrates professional software engineering practices including clear separation of concerns, event-driven architecture, and comprehensive documentation.

**Overall Assessment:** The software is **fit for purpose** as an alpha-stage game with some bugs and areas requiring attention before production release.

| Category | Rating | Notes |
|----------|--------|-------|
| Architecture | **Excellent** | Clean service-oriented design with EventBus pattern |
| Code Quality | **Good** | Consistent style, well-documented, some issues |
| Correctness | **Needs Work** | Several logic bugs identified |
| Completeness | **Alpha** | Core systems present, some features placeholder |
| Security | **Good** | Minimal attack surface for single-player game |
| Performance | **Good** | Proper caching, chunked terrain, reasonable complexity |

---

## Critical Issues (Must Fix)

### 1. CRITICAL: Terrain Zone Classification Bug

**File:** `src/core/enums.gd:331-343`
**Severity:** High
**Impact:** Gameplay - STEEP terrain zone is unreachable

The `get_terrain_zone()` function has a logic error where the `TerrainZone.STEEP` case can never be returned:

```gdscript
static func get_terrain_zone(slope_angle: float) -> TerrainZone:
    # ...
    elif slope_angle >= SLOPE_THRESHOLDS.slide_min:    # 25.0
        return TerrainZone.SLIDEABLE
    elif slope_angle >= SLOPE_THRESHOLDS.walkable_max: # 25.0 - NEVER REACHED!
        return TerrainZone.STEEP
```

Both `slide_min` and `walkable_max` are set to 25.0 degrees. Since the SLIDEABLE check comes first, any slope >= 25 degrees returns SLIDEABLE, making the STEEP zone (25-35 degrees) unreachable.

**Recommendation:** Reorder the checks or adjust thresholds:
```gdscript
# Option 1: Check STEEP first (narrower range)
elif slope_angle >= SLOPE_THRESHOLDS.downclimb_min:  # 35.0
    return TerrainZone.DOWNCLIMB
elif slope_angle >= SLOPE_THRESHOLDS.walkable_max:   # 25.0
    # Both STEEP and SLIDEABLE apply to 25-35 degrees
    # Return SLIDEABLE if surface allows, else STEEP
    return TerrainZone.SLIDEABLE  # Or add surface-type logic
```

---

### 2. HIGH: Missing Null Checks in Run Context

**File:** `src/core/data/run_context.gd:317-318`
**Severity:** High
**Impact:** Potential crash when generating run summary

The `get_run_summary()` function accesses `body_state` properties without null checking:

```gdscript
func get_run_summary() -> Dictionary:
    # ...
    "final_fatigue": body_state.fatigue,           # Crash if body_state is null
    "injuries": body_state.injuries.size(),        # Crash if body_state is null
```

**Recommendation:** Add null checks:
```gdscript
"final_fatigue": body_state.fatigue if body_state else 0.0,
"injuries": body_state.injuries.size() if body_state else 0,
```

---

### 3. HIGH: Player State Machine Missing Null Safety

**File:** `src/entities/player/player_state_machine.gd`
**Severity:** High
**Impact:** Potential crashes during state transitions

Multiple state transition functions access `player.current_cell` properties without complete null checking:

```gdscript
func _check_sliding() -> bool:
    if player.current_cell == null:
        return false
    # But later in code, current_cell properties accessed without re-checking
```

**Recommendation:** Add defensive null checks for all terrain queries or cache the cell reference locally.

---

## Medium Issues (Should Fix)

### 4. MEDIUM: Weather Window Time Wrapping Bug

**File:** `src/systems/environment/weather_service.gd:153-158`
**Severity:** Medium
**Impact:** Weather windows may not trigger correctly near midnight

```gdscript
window.start_time = start_hour + i * window_duration
if window.start_time >= 24.0:
    window.start_time -= 24.0
window.end_time = window.start_time + window_duration
if window.end_time >= 24.0:
    window.end_time -= 24.0
```

When `end_time` wraps around midnight (e.g., start=23, end=1), the `is_active()` check fails:
```gdscript
func is_active(current_time: float) -> bool:
    return current_time >= start_time and current_time < end_time
    # Fails when start_time=23 and end_time=1
```

**Recommendation:** Handle midnight wrapping in `is_active()`:
```gdscript
func is_active(current_time: float) -> bool:
    if end_time > start_time:
        return current_time >= start_time and current_time < end_time
    else:  # Wraps around midnight
        return current_time >= start_time or current_time < end_time
```

---

### 5. MEDIUM: Surface Friction Missing Entries

**File:** `src/core/enums.gd:314-324`
**Severity:** Medium
**Impact:** Some surface types return default friction

`SURFACE_FRICTION` dictionary is missing entries for:
- `SurfaceType.SNOW_PACKED`
- `SurfaceType.GRASS`
- `SurfaceType.MUD`

These surfaces will fall back to the default value of 0.5, which may not be correct.

**Recommendation:** Add missing friction values:
```gdscript
const SURFACE_FRICTION := {
    # ... existing entries ...
    SurfaceType.SNOW_PACKED: 0.35,
    SurfaceType.GRASS: 0.65,
    SurfaceType.MUD: 0.25,
}
```

---

### 6. MEDIUM: Input Buffer Memory Growth

**File:** `src/entities/player/player_input.gd:147-149`
**Severity:** Medium
**Impact:** Potential memory growth under extreme latency

The input buffer is limited to 10 entries but entries are only processed when delay expires. Under extreme delay conditions, this could lead to stale input being processed.

```gdscript
while input_buffer.size() > 10:
    input_buffer.pop_front()
```

**Recommendation:** Also limit entries by age, not just count.

---

### 7. MEDIUM: Async Service Dependencies

**File:** Multiple files using `ServiceLocator.get_service_async()`
**Severity:** Medium
**Impact:** Race conditions if service methods called before callback

Pattern used throughout:
```gdscript
func _ready() -> void:
    ServiceLocator.get_service_async("TimeService", _on_time_service_ready)
    # Methods could be called before _on_time_service_ready fires
```

**Recommendation:** Add `is_ready` flags or use await patterns where appropriate.

---

## Low Issues (Consider Fixing)

### 8. LOW: Hardcoded Paths in Save Manager

**File:** `src/systems/save/save_manager.gd:27-31`
**Severity:** Low
**Impact:** Inflexibility for different save locations

```gdscript
const PROFILE_PATH := "user://player_profile.json"
const HISTORY_PATH := "user://run_history.json"
```

**Recommendation:** Make paths configurable for cloud saves, multiple profiles, etc.

---

### 9. LOW: Magic Numbers Throughout

**Files:** Various
**Severity:** Low
**Impact:** Maintainability

Examples:
- `fatal_event_manager.gd:46-49`: Threshold values not explained
- `slide_system.gd`: Speed multipliers without constants
- `risk_calculator.gd:37-43`: Threshold values inline

**Recommendation:** Extract magic numbers to named constants with documentation.

---

### 10. LOW: Inconsistent Enum Naming

**File:** `src/core/enums.gd`
**Severity:** Low
**Impact:** Minor code clarity issue

Some enums have redundant prefixes:
- `SurfaceType.SNOW_FIRM` vs `SurfaceType.ROCK` (inconsistent granularity)
- `SlideControlLevel.CONTROLLED` vs `SlideOutcome.CLEAN_STOP` (different verb forms)

**Recommendation:** Standardize enum naming conventions.

---

## Architecture Review

### Strengths

1. **EventBus Pattern**: Excellent use of a central signal hub with 150+ signals organized by category. Provides clean decoupling between systems.

2. **Service Locator Pattern**: Proper dependency injection with async service resolution. Well-implemented central registry.

3. **State Machine Pattern**: Clean implementation for both game state and player movement state with validated transitions.

4. **Data Classes**: Proper separation of data (BodyState, GearState, RunContext) from behavior.

5. **Documentation**: Extensive inline documentation explaining design philosophy and rationale.

### Areas for Improvement

1. **Error Handling**: Many functions silently return default values on error rather than logging or propagating issues.

2. **Testing**: No automated tests observed in the repository structure.

3. **Type Safety**: GDScript's dynamic typing leads to some runtime risks that could be caught with stricter typing.

---

## Fitness for Purpose Assessment

### Core Gameplay Systems

| System | Status | Notes |
|--------|--------|-------|
| Player Movement | **Functional** | Well-implemented with state machine |
| Sliding Mechanics | **Functional** | Core mechanic works, physics reasonable |
| Rope System | **Functional** | Complete deployment/anchor system |
| Terrain System | **Functional** | DEM support, chunked loading |
| Weather System | **Functional** | Dynamic transitions, window wrapping bug |
| Body Condition | **Functional** | Fatigue, cold, injury tracking |
| Camera Director | **Functional** | Sophisticated AI cinematography |
| Fatal Events | **Functional** | Ethical 5-phase death handling |
| Save System | **Functional** | JSON persistence with backup |

### Design Goals Alignment

1. **"Consequence over Conquest"**: The systems support this philosophy through:
   - Fatigue accumulation mechanics
   - Injury system with persistent effects
   - Fatal event handling that respects the weight of failure
   - No "winning" mechanic - only survival metrics

2. **"Diegetic Feedback"**: Implemented through:
   - Body state communicated via breathing/camera effects
   - No HUD stamina bars
   - Self-check action for condition assessment

3. **"Ethical Streaming"**: Properly implemented:
   - 5-phase death sequence with respectful camera behavior
   - Predictive fade options
   - No exploitation of fatal moments

---

## Performance Considerations

### Positive Aspects

1. **Terrain Chunking**: Proper chunked terrain loading prevents memory issues
2. **Cell Caching**: `TerrainService` caches recent cell queries
3. **Signal Optimization**: EventBus pattern avoids expensive polling

### Potential Concerns

1. **Per-Frame Processing**: Several systems process every frame when they could use timers
2. **Dictionary Lookups**: Heavy use of dictionary string keys in hot paths
3. **Terrain Reclassification**: `update_surface_conditions()` reclassifies all loaded chunks

---

## Security Assessment

As a single-player offline game, the security attack surface is minimal. However:

### Observations

1. **Save Files**: JSON format is human-readable/editable (not encrypted)
   - Acceptable for single-player game
   - Players can modify their own saves

2. **No Network Code**: No multiplayer or online features observed

3. **File Operations**: Proper use of `user://` paths, no arbitrary file access

---

## Recommendations Summary

### Priority 1 (Before Beta)
- [ ] Fix terrain zone classification bug in `enums.gd`
- [ ] Add null checks in `run_context.gd`
- [ ] Add null safety to player state machine
- [ ] Fix weather window midnight wrapping

### Priority 2 (Before Release)
- [ ] Add missing surface friction values
- [ ] Implement proper error handling/logging
- [ ] Add basic unit tests for core systems
- [ ] Review async service initialization patterns

### Priority 3 (Post-Release)
- [ ] Extract magic numbers to constants
- [ ] Standardize enum naming
- [ ] Performance profiling and optimization
- [ ] Consider save file versioning for future updates

---

## Conclusion

Long-Home demonstrates excellent software architecture and thoughtful game design. The codebase is well-organized, documented, and follows consistent patterns. The identified issues are typical for alpha-stage software and none are fundamental architectural problems.

The software is **fit for purpose** as an alpha release with the caveat that the critical bugs (terrain zone, null safety) should be addressed before broader testing. The design goals are well-supported by the implementation, and the ethical considerations for death handling are notably well-executed.

**Overall Grade: B+**

The project shows strong engineering fundamentals and a clear vision. With the identified fixes applied, this would be ready for beta testing.

---

*Generated by automated audit - manual review recommended for all findings.*
