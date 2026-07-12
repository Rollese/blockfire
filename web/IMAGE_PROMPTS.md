# Blockfire — marketing image prompts (6 gallery scenes)

Prompts for the six website gallery images. They target the **art style** of the existing
main-menu wallpaper (`client/art/menu/menu_background.png`, made with OpenAI `gpt-image-1`):
low-poly / blocky voxel style, flat-shaded simple geometry, soft ambient occlusion, muted
military palette. **Vary the time of day and weather across the six — daytime only, no night
combat.** **No UI, no HUD, no text, no logos, no watermarks.**

## How to use

- **Best results:** generate in a tool that can take a *style reference image* — feed it the
  existing `menu_background.png` and say "match this art style (but not necessarily its sunset
  lighting)," then use a prompt below.
- **Aspect ratio:** 16:9 landscape for all six.
- **Append the shared style block** (below) to every prompt for a consistent look; each prompt
  sets its own **time of day + weather** so the set feels varied.
- Where you land the finished files, tell me and I'll optimize them to WebP and drop them into
  `web/site/assets/shots/` (replacing `shot-01.svg … shot-06.svg`).

### Shared style block (append to each prompt)

> Low-poly, blocky voxel-style game art; flat-shaded simple geometry; soft ambient occlusion;
> muted military color palette (olive, tan, gunmetal); clean, cinematic, high quality.
> Third-person cinematic camera. Daytime scene. No user interface, no HUD, no health bars, no
> text, no numbers, no logos, no watermark, no signature, no night, no darkness.

---

## 1 — Large-Scale Conquest  ·  bright clear midday  (wide establishing → gallery tile 1)

> A sweeping wide establishing shot of a huge low-poly battlefield at **bright midday under a
> clear deep-blue sky, strong overhead sun and crisp hard shadows**: a sprawling blocky town of
> simple houses and a few taller buildings, with dozens of tiny blocky soldiers in two teams
> advancing across open green fields and roads toward the objectives. Two glowing capture-point
> flags — one blue, one red — planted on rooftops, each ringed by a soft colored circle on the
> ground. Thin columns of smoke rise in the distance. Epic scale, lots of depth and distance.

## 2 — Destructible Buildings  ·  overcast, dusty  (gallery tile 2)

> A low-poly two- or three-storey building with a large section of one wall blown wide open under
> a **flat, overcast grey-white afternoon sky with soft diffuse light**, chunks of blocky rubble
> and a heavy rolling dust cloud spilling out, the interior rooms exposed. A small squad of blocky
> soldiers breaches through the gap, weapons raised. Muted, gritty daylight. Sense of a wall just
> having been destroyed mid-battle.

## 3 — Class-Based Loadouts  ·  warm late-afternoon sun  (gallery tile 3)

> Four blocky low-poly soldiers advancing together as a squad in **warm late-afternoon sunlight
> with long soft shadows and a hazy golden sky**, each clearly a different class: an Assault trooper
> with a rifle, a Medic with a red-cross backpack, an Engineer carrying a rocket launcher and tools,
> and a Support gunner shouldering a light machine gun. Cohesive squad silhouette, gentle rim light,
> shallow depth of field, a low-poly town softly blurred behind. Heroic hero-shot framing.

## 4 — Close-Quarters Combat  ·  bright day through the windows  (gallery tile 4)

> Interior of a blocky low-poly building during a close-quarters firefight, with **bright midday
> daylight and a clear blue sky visible through broken windows and a blown-open wall**, hard shafts
> of white light cutting across the room and dust motes drifting in them. A soldier peeks around a
> doorway with a muzzle flash; another vaults a low wall. Tense, dynamic, tight interior space, cool
> shadows against warm daylight.

## 5 — Overwatch  ·  misty morning  (wide → gallery tile 5)

> A lone blocky support marksman kneeling on a grassy low-poly ridge on a **cool, misty early
> morning with low ground fog, a pale soft sky and gentle diffuse light**, looking out over a vast
> rolling valley and a small village far below, with very long sightlines fading into the haze.
> Calm, atmospheric, huge sense of depth. Camera just behind and above the soldier's shoulder.

## 6 — Hold the Point  ·  rainy overcast day  (gallery tile 6)

> Defenders dug in at a fortified capture point during a **grey rainy daytime storm — dark
> blue-grey clouds, falling rain, wet reflective ground and puddles, but clearly daytime**: sandbag
> walls and a deployed low-poly machine-gun nest with a blocky gunner manning it, a capture-point
> flag beside them ringed by a glowing colored circle on the ground. Blocky enemy soldiers advance
> as silhouettes through the rain and mist in the middle distance. Dramatic, wet, embattled mood.

---

_All six should read as the same game and art style as the menu wallpaper, but spanning different
times of day and weather (bright midday, overcast, warm afternoon, misty morning, rainy day) —
**daytime only, never night.** Generate at the highest quality your tool offers; I'll handle
resizing/optimization._
