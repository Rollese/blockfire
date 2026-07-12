# Blockfire — marketing image prompts (6 gallery scenes)

Prompts for generating the six website gallery images. They target the **same look as
the existing main-menu wallpaper** (`client/art/menu/menu_background.png`, made with
OpenAI `gpt-image-1`): low-poly / blocky voxel style, flat-shaded simple geometry,
golden-hour lighting, soft atmospheric haze, muted military palette with a warm sun.
**No UI, no HUD, no text, no logos, no watermarks.**

## How to use

- **Best results:** generate in a tool that can take a *style reference image* — feed it
  the existing `menu_background.png` and say "match this art style," then use a prompt below.
- **Aspect ratio:** 16:9 landscape for all six (they fill wide gallery tiles). A couple are
  marked "wide establishing" — give those extra horizontal room if the tool allows.
- **Append the shared style block** (below) to every prompt for consistency.
- Where you land the finished files, tell me and I'll optimize them to WebP and drop them
  into `web/site/assets/shots/` (replacing `shot-01.svg … shot-06.svg`).

### Shared style block (append to each prompt)

> Low-poly, blocky voxel-style game art; flat-shaded simple geometry; golden-hour sunset
> lighting with soft ambient occlusion and gentle atmospheric haze; muted military color
> palette (olive, tan, gunmetal) warmed by an orange sun; clean, cinematic, high quality.
> Third-person cinematic camera. No user interface, no HUD, no health bars, no text, no
> numbers, no logos, no watermark, no signature.

---

## 1 — Large-Scale Conquest  (wide establishing → gallery tile 1)

> A sweeping wide establishing shot of a huge low-poly battlefield at golden hour: a sprawling
> blocky town of simple houses and a few taller buildings, with dozens of tiny blocky soldiers
> in two teams advancing across open green fields and roads toward the objectives. Two glowing
> capture-point flags — one blue, one red — planted on rooftops, each ringed by a soft colored
> circle on the ground. Thin columns of smoke rise in the distance; dramatic sunset sky with
> blocky clouds. Epic scale, lots of depth and distance.

## 2 — Destructible Buildings  (gallery tile 2)

> A low-poly two- or three-storey building with a large section of one wall blown wide open,
> chunks of blocky rubble and a rolling dust cloud spilling out, the interior rooms exposed.
> A small squad of blocky soldiers breaches through the gap, weapons raised. Warm sunset light
> rakes across the debris. Sense of a wall just having been destroyed mid-battle.

## 3 — Class-Based Loadouts  (gallery tile 3)

> Four blocky low-poly soldiers advancing together as a squad, each clearly a different class:
> an Assault trooper with a rifle, a Medic with a red-cross backpack, an Engineer carrying a
> rocket launcher and tools, and a Support gunner shouldering a light machine gun. Cohesive
> squad silhouette, golden-hour rim light behind them, shallow depth of field, a low-poly town
> softly blurred in the background. Heroic hero-shot framing.

## 4 — Close-Quarters Combat  (gallery tile 4)

> Interior of a blocky low-poly building during a close-quarters firefight: a soldier peeking
> around a doorway with a muzzle flash, another vaulting a low wall, warm shafts of sunset light
> streaming through broken windows and a blown-open wall, dust motes in the light. Tense,
> dynamic, cinematic, tight interior space.

## 5 — Overwatch  (wide → gallery tile 5)

> A lone blocky support marksman kneeling on a grassy low-poly ridge, looking out over a vast
> rolling valley of hills and a small village far below, with very long sightlines to distant
> low-poly buildings and roads. Golden-hour sun low on the horizon, layered atmospheric haze
> giving huge depth. Calm, cinematic, wide vista. Camera just behind and above the soldier's
> shoulder.

## 6 — Hold the Point  (gallery tile 6)

> Defenders dug in at a fortified capture point at dusk: sandbag walls and a deployed low-poly
> machine-gun nest with a blocky gunner manning it, a capture-point flag beside them ringed by a
> glowing colored circle on the ground. Blocky enemy soldiers advance as silhouettes in the
> hazy middle distance. Warm-vs-cool lighting, a last-stand mood, embers and light smoke.

---

_All six should read as the same game and the same golden-hour world as the menu wallpaper.
Generate at the highest quality your tool offers; I'll handle resizing/optimization._
