# Third-Party IP in This Repository

This repository includes the following unmodified third-party IP cores. Each is used as-is from its upstream source without local modifications.

---

## 1. picorv32.v

**Source:** [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32)  
**Version:** Commit hash not tracked — copy taken from upstream master branch  
**License:** ISC License (functionally equivalent to MIT)

**License text from file header:**
```
Copyright (C) 2015  Claire Xenia Wolf <claire@yosyshq.com>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

**Role in this project:** RISC-V (RV32I) CPU core. Instantiated in `top.sv` and connected via the AXI interconnect. Not modified.

---

## 2. simpleuart.v

**Source:** Part of the PicoSoC example SoC from [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) (same repo as picorv32)  
**License:** ISC License (same copyright holder as picorv32)

**License text from file header:**
```
Copyright (C) 2017  Claire Xenia Wolf <claire@yosyshq.com>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

**Role in this project:** UART peripheral with AXI register interface. Connected at address `0x18000` via `axi_interconnect.sv`. Also used with `simpleuart_controller.sv` (local wrapper). Not modified.

---

## 3. simplegpio.sv

**Source:** Original hackathon work (ReRAM in-memory-compute accelerator + SoC integration) — listed in README §6 as "original hackathon work", NOT third-party IP. However, the name `simplegpio` and its AXI4-Lite interface style closely match the PicoSoC `simplegpio.v` pattern from the same picorv32 repo. If it is derived from that source, it would carry the same ISC license.

**License text from file header:** *None present in file*

**Role in this project:** GPIO peripheral with AXI register interface. Connected at address `0x20000` via `axi_interconnect.sv`. No license header found in the file — the README classifies this as "original hackathon work" along with `imc_*`, `reram_array.sv`, `axi_interconnect.sv`, `axi_interf.sv`, `simplemem*.sv`, `simpleuart_controller.sv`, `top.sv`.

**Note:** If `simplegpio.sv` is confirmed to be derived from the PicoSoC `simplegpio.v`, its license is ISC per Claire Wolf. If it is original hackathon code, it falls under the repository's own license (to be determined).

---

## Summary Table

| File | Source | License | Modified? |
|------|--------|---------|-----------|
| `rtl/picorv32.v` | YosysHQ/picorv32 | ISC | No |
| `rtl/simpleuart.v` | YosysHQ/picorv32 (PicoSoC) | ISC | No |
| `rtl/simplegpio.sv` | Hackathon original (or PicoSoC-derived) | Unknown / ISC if derived | No |

---

**Important:** The ISC license requires preserving the copyright notice and permission notice in all copies. Both `picorv32.v` and `simpleuart.v` already contain these headers in-file, which this repository retains verbatim. If `simplegpio.sv` is confirmed PicoSoC-derived, a license header should be added to that file.