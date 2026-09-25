# BootLife contribution preparation

Reviewed: [CONTRIBUTING.md](https://github.com/0xAX/BootLife/blob/master/CONTRIBUTING.md).
A pinned copy is supplied at `upstream/CONTRIBUTING.md`.

On 2026-09-25, remote `master` resolved to
`86dc8d932db282097fd157e2c65051af7a3dd118`, the experiment's existing base.
The current upstream `life.asm` SHA-256 was
`ffb15d81f1c98a871d72dc83333abf33dff6f26cb1ba69750f826a29aaf8070e`,
matching `upstream/life.asm`.

The guide permits an improvement issue or a direct pull request. For a PR it
asks for a fork, local changes, commits and a push, a rebase onto current master
before pushing, a description explaining the changes, a related issue link if
applicable, and responses to review. It does not require an issue before a PR,
a particular benchmark framework, or an article format. No rebased upstream
branch or maintainer approval is implied by this local research package.

## Proposed review scope

First agree on the finite dead-border behavior. The original linear neighbor
addressing crosses row seams; correcting that and restricting glider origins
changes output near the edges. The final candidates deliberately implement
finite 320×200 Life, so do not describe them as preserving every upstream pixel.

Then choose a target rather than merging every alternative into `life.asm`:

- `sliding`: smallest tested finite-grid payload, 408 bytes.
- `rolling_sliding`: 966 work bytes, 467-byte payload; preferred low-RAM candidate
  in the corrected run.
- `rolling_lut`: 3,526 work bytes, 490-byte payload.
- `sliding_lut`: 68,096 work bytes, 431-byte payload.
- `sliding_lut_word`: fastest observed kernel, 68,096 work bytes, 473-byte payload.
- `rolling_bits`: tested 64-byte embedded-table alternative, 966 work bytes,
  full 510-byte payload; included for comparison, not the observed low-RAM winner.

Keep the original ISC notices. Recheck the remote branch before an actual push;
the recorded commit is an observation, not a guarantee about future master.

## Suggested PR explanation

The finite-grid kernel gives edge cells explicit dead neighbors and prevents
injected gliders from crossing row boundaries. Horizontal sliding windows reuse
vertical column information. The selected implementation trades code space,
working RAM, and table size while retaining byte aging, the palette, injections,
and normal BIOS pacing in a complete 512-byte boot sector.

Validation boots actual NASM images through BIOS and compares every output byte
against an independent finite-grid/injection model, including boundary and guard
checks. The article documents all alternatives and the debugger-overhead
correction. Cite corrected QEMU host timings only; neither physical Pentium
speed nor monitor FPS is established by those kernel numbers.

Attach the selected assembly, the article, reproduction commands, and the
relevant result/manifest files. Link an existing issue only if there is one.
