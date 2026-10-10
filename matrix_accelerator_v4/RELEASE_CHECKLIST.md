# v4.0.0 release candidate checklist

Preparation date: 2026-10-10. Repository branch: `main`. Existing repository contents retained; only `matrix_accelerator_v4/` is intended as the new release package.

- [x] Inspected existing RTL, testbenches, documents, Git status, README and release notes.
- [x] Located Step 9H-C combined design and testbench.
- [x] Copied 15 existing RTL modules; exactly one definition per module in each supported compile set.
- [x] Confirmed exact module-body equivalence between separate RTL and combined design; combined file copied verbatim.
- [x] Preserved upstream DMA file and complete copyright/license notice verbatim.
- [x] Confirmed staging DRAIN fix and `matrix_dma_compute_top` top.
- [x] Included architecture, verification plan, limitations and recovery report.
- [x] Recorded historical Step 9H-B and Step 9H-C results separately from local verification.
- [x] Prepared Icarus runner with `-Wall -g2012`, `tb_step9h_c`, explicit sources and temporary outputs.
- [x] `tb/step9h_a_testbench.sv` present; copied unchanged from repository `tb/`.
- [x] `tb/step9h_b_testbench.sv` present; user supplied the corrected candidate source. Repository-level file remains the older version.
- [x] `tb/step9h_c_testbench.sv` present; matches EDA Playground testbench verbatim.
- [x] Historical EDA Playground Step 9H-B: 5/5 tests passed; Errors=2, RecoveryJobs=3.
- [x] Historical EDA Playground Step 9H-C: 6/6 randomized stress jobs passed.
- [x] Corrected Step 9H-B source checks completed. All three Step 9H testbenches are present. The corrected Step 9H-B candidate source uses registered RVALID and R payload, holds them during stalls, includes a procedural stability assertion, and checks B-DECERR descriptor, AR, status and B error coverage. All five error/reset recovery scenarios are present. These are source-inspection findings; historical EDA Playground PASS results remain distinct from local simulation. The repository-level Step 9H-B file is an older version; the corrected candidate file is the release source. Testbench contents were not modified during final preparation.
- [x] Complete expected-file/structure gate: all 29 expected files present.
- [x] Static module dependency review: all instantiated RTL module types are included; compile/elaboration remains unverified without Icarus.
- [ ] Local compilation/regression: unavailable (`iverilog` and `vvp` not on PATH); no PASS claimed.
- [x] Working-tree `git diff --check` and new-candidate whitespace check passed after normalizing copied Markdown line breaks.
- [x] Final working-tree and staged whitespace checks and complete staged-content review completed before the local commit.
- [x] Local release commit prepared with only `matrix_accelerator_v4/`; message: `Prepare v4.0.0 matrix accelerator release candidate`.

Publication is outside this task. Before stronger release signoff, run the local regressions when Icarus is available, archive full logs, and assess the open verification risks. No push, tag, PR, release or remote modification is authorized.
