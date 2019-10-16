# ASAP-DartGraphTools

This is a collection of the *old* (Summer 2018) files needed for graph generation (eg, modified DART), conversion (adj2g & g2mtx) and coloring (ColPack) codes.

These are here simply for generating test data sets until these capability are updated and merged into DART itself.

The generation of the graph will be done in the future just with the obs file and the DART namelist (for cutoff & other relevant values), not a run of the DART code itself.
The ColPack software will be deprecated for some real-time, less-perfect but faster coloring code (spatially aware?).
The conversion routines won't be necessary, since we won't be swapping between formats - but it'd be great to have the format we DO use by writable/readable from standard graph formats, for testing 'better' graphs.
