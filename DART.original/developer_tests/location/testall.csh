#!/bin/csh
#
# DART software - Copyright UCAR. This open source software is provided
# by UCAR, "as is", without charge, subject to all terms of use at
# http://www.image.ucar.edu/DAReS/DART/DART_download
#
# DART $Id: testall.csh 11626 2017-05-11 17:27:50Z nancy@ucar.edu $

# this script builds and  runs the location test code for each of the
# possible location modules.

set LOCLIST = 'annulus column oned threed_sphere twod twod_sphere threed threed_cartesian'

# clean up from before
foreach i ( $LOCLIST )
   # do not cd so as to not accidently remove files in the
   # wrong place if the cd fails.
  rm -f $i/test/*.o \
        $i/test/*.mod \
        $i/test/input.nml*_default \
        $i/test/dart_log.* \
        $i/test/Makefile \
        $i/test/location_test_file* \
        $i/test/location_test
end


# and now build afresh and run tests
foreach i ( $LOCLIST )

 echo
 echo
 echo "=================================================================="
 echo "=================================================================="
 echo "Starting tests of location module $i at "`date`
 echo "=================================================================="
 echo "=================================================================="
 echo
 echo

 set FAILURE = 0

 cd $i/test

 ./mkmf_location_test
 make || set FAILURE = 1
 ls -l location_test
 ./location_test  < test.in || set FAILURE = 1

 cd ../..

 echo
 echo
 echo "=================================================================="
 echo "=================================================================="
 if ( $FAILURE ) then
   echo
   echo "ERROR - unsuccessful build of location module $i at "`date`
   echo
 else
   echo "Tests of location module $i complete at "`date`
 endif
 echo "=================================================================="
 echo "=================================================================="
 echo
 echo
end

exit 0

# <next few lines under version control, do not edit>
# $URL: https://svn-dares-dart.cgd.ucar.edu/DART/releases/Manhattan/developer_tests/location/testall.csh $
# $Revision: 11626 $
# $Date: 2017-05-11 11:27:50 -0600 (Thu, 11 May 2017) $
