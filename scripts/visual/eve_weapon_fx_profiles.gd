extends RefCounted

## Entirely new combat art direction, 2026-11-04. Width includes the glow halo.
const COLORS := {
	&"laser": Color(1.0, 0.55, 0.10),
	&"hybrid": Color(0.14, 1.0, 0.68),
	&"proj": Color(1.0, 0.24, 0.035),
	&"missile": Color(0.15, 0.55, 1.0),
}
const WEAPONS: Array[StringName] = [&"laser", &"hybrid", &"proj", &"missile"]
const CANNON_MOUNT_STAGGER := .075
# Use the former close-range arrival time at every engagement distance.
const HYBRID_ARRIVAL_TIME := 0.14

static func cannon_mount_count(tier: int) -> int:
	return 2 if tier <= 2 else (3 if tier == 3 else 4)

static func color_of(weapon: StringName) -> Color:
	return COLORS.get(weapon, COLORS[&"laser"])

static func scale_of(tier: int, star: int = 1, logistics: bool = false) -> float:
	var size := 0.72 + 0.13 * clampi(tier, 1, 5)
	size *= 1.0 + 0.06 * maxi(0, star - 1)
	return size * (0.72 if logistics else 1.0)
