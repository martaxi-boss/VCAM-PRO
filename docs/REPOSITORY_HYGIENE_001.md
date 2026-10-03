# Repository Hygiene 001

Owner-authorized cleanup, 2026-10-03, VCAM-PRO only.
Baseline: `f4087e8607929e6b3ff3c6b594e8e43cc6b0b2d8`.

## Findings and changes

README still declared implementation not started. PROJECT_STATE described only
a load probe and prohibited substitution. The canonical state ledger contained
contradictory duplicate keys and ended at an older package. Replaced these entry
points with the current contract and verified VIDEO remediation evidence.

Two obsolete certifications failed on the accepted baseline: activation run
`36717911234` and multi-geometry run `36717911342`. Both final canonical gates
were successful. Removed superseded diagnostic packages and 16 workflows after
checking executable dependencies. Removed three standalone historical pre-fix
fixtures and the multi-geometry historical reproduction job. Kept all current
regression tests and frame-engine stages.

Five earlier certifications with focused regression coverage are explicit manual
dispatch only. Removed obsolete source-blob locks from these workflows while
retaining ancestry/filter checks. Both final gates now recertify metadata and
workflow-routing changes on the exact new commit.

## Removed scopes

- `product/activation_parity_device_remediation_001`
- `product/first_local_photo_virtual_substitution_001`
- `product/full_product_real_hook_001`
- `product/hook_installation_readiness_gate`
- `product/hook_reachability_gate`
- `product/ios15_usb_activation_semantics_parity_001`
- `product/legacy_real_hook_linkage_gate`
- `product/legacy_real_hook_runtime_activation_gate`
- `product/local_photo_pipeline_ready_pass_through_001`
- `product/photo_geometry_working_set_001`
- `product/real_camera_callback_pass_through_001`
- `product/runtime_gate`
- `proofs/mediaserverd_load_probe`

## Manual historical certifications

- `local-media-device-proof-remediation-001-ci.yml`
- `photo-multi-geometry-stability-001-ci.yml`
- `device-proof-followup-video-adjust-media-001-ci.yml`
- `photo-geometry-working-set-001-ci.yml`
- `post-photo-local-media-convergence-001-ci.yml`

## Preservation and verification

No production source or current packaging input changed. Existing checkpoint,
evidence and archive tags preserve rollback. Removed files remain in Git history;
no history rewrite, merge, release, deploy or device operation was performed.

Local checks: diff whitespace, YAML parsing, shell syntax and executable path
references. Final verification requires both canonical GitHub gates on the new
SHA. CI evidence is separate from physical VIDEO proof, still pending retry.
