# docs

- **`screenshots/`** - renders of the real UI, regenerated from the code
  rather than photographed, plus two phone photos from the night the boot
  chain first worked end to end. See the main README for how they are
  produced.
- **`nocturne-grub.cfg`** - the Slate's real 25-entry GRUB config, kept as a
  regression fixture. `discover-kernels.sh` is tested against it because two
  of its bugs were only ever going to show up against a real one: nested
  `menuentry` stanzas inside "Advanced options", and several menu entries
  sharing a single kernel image.

Hardware findings and the reasoning behind decisions live in the README of
whichever directory they belong to, rather than being collected here - they
are far more likely to be read next to the code they explain.
