      FUNCTION IREADNS(LUNIT,SUBSET,IDATE)

C$$$  SUBPROGRAM DOCUMENTATION BLOCK
C
C SUBPROGRAM:    IREADNS
C   PRGMMR: WOOLLEN          ORG: NP20       DATE: 1994-01-06
C
C ABSTRACT: THIS FUNCTION CALLS BUFR ARCHIVE LIBRARY SUBROUTINE READNS
C   AND PASSES BACK ITS RETURN CODE.  SEE READNS FOR MORE DETAILS.
C
C PROGRAM HISTORY LOG:
C 1994-01-06  J. WOOLLEN -- ORIGINAL AUTHOR (ENTRY POINT IN IREADMG)
C 2002-05-14  J. WOOLLEN -- CHANGED FROM AN ENTRY POINT TO INCREASE
C                           PORTABILITY TO OTHER PLATFORMS
C 2003-11-04  S. BENDER  -- ADDED REMARKS/BUFRLIB ROUTINE
C                           INTERDEPENDENCIES
C 2003-11-04  D. KEYSER  -- UNIFIED/PORTABLE FOR WRF; ADDED
C                           DOCUMENTATION (INCLUDING HISTORY)
C DART $Id: ireadns.f 4942 2011-06-02 20:51:48Z thoar $
C
C USAGE:    IREADNS (LUNIT, SUBSET, IDATE)
C   INPUT ARGUMENT LIST:
C     LUNIT    - INTEGER: FORTRAN LOGICAL UNIT NUMBER FOR BUFR FILE
C
C   OUTPUT ARGUMENT LIST:
C     SUBSET   - CHARACTER*8: TABLE A MNEMONIC FOR BUFR MESSAGE
C                CONTAINING SUBSET BEING READ
C     IDATE    - INTEGER: DATE-TIME STORED WITHIN SECTION 1 OF BUFR
C                MESSAGE CONTAINING SUBSET BEING READ, IN FORMAT OF
C                EITHER YYMMDDHH OR YYYYMMDDHH, DEPENDING ON DATELEN()
C                VALUE
C     IREADNS  - INTEGER: RETURN CODE:
C                       0 = normal return
C                      -1 = there are no more subsets in the BUFR file
C
C REMARKS:
C    THIS ROUTINE CALLS:        READNS
C    THIS ROUTINE IS CALLED BY: None
C                               Normally called only by application
C                               programs.
C
C ATTRIBUTES:
C   LANGUAGE: FORTRAN 77
C   MACHINE:  PORTABLE TO ALL PLATFORMS
C
C$$$

      CHARACTER*8 SUBSET
      CALL READNS(LUNIT,SUBSET,IDATE,IRET)
      IREADNS = IRET
      RETURN
      END