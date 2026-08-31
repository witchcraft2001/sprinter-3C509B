# Third-party test code

`tools/exe-harness/Z80core.js` is Molly Howell's Z80 interpreter, adapted from
the local `sprinter-lha` test harness and used only by host-side tests. It is
distributed under the MIT license in `tools/exe-harness/LICENSE.Z80core`.

Imported source SHA-256:
`44a0398fdf763aca6cd3608777f4b30aa53ceb4d0ec2f7234422ceb44980def0`.

The Z80 core is not linked into DSS executables or included in IMG/ZIP runtime
artifacts.
