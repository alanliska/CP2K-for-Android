!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_dist_util
   !! DBCSR sparse matrix utility routines

   USE dbcsr_array_types, ONLY: array_data
   USE dbcsr_data_methods, ONLY: dbcsr_data_get_size, &
                                 dbcsr_data_get_size_referenced, &
                                 dbcsr_get_data
   USE dbcsr_dist_methods, ONLY: dbcsr_distribution_local_cols, &
                                 dbcsr_distribution_local_rows, &
                                 dbcsr_distribution_mp, &
                                 dbcsr_distribution_ncols, &
                                 dbcsr_distribution_nlocal_cols, &
                                 dbcsr_distribution_nlocal_rows, &
                                 dbcsr_distribution_nrows
   USE dbcsr_kinds, ONLY: dp, &
                          int_4, &
                          int_8, &
                          real_4, &
                          real_8
   USE dbcsr_methods, ONLY: dbcsr_blk_col_offset, &
                            dbcsr_blk_row_offset, &
                            dbcsr_has_symmetry, &
                            dbcsr_valid_index
   USE dbcsr_mp_methods, ONLY: dbcsr_mp_group, &
                               dbcsr_mp_mypcol, &
                               dbcsr_mp_myprow
   USE dbcsr_mpiwrap, ONLY: mp_sum
   USE dbcsr_toollib, ONLY: sort, &
                            swap
   USE dbcsr_types, ONLY: &
      dbcsr_distribution_obj, dbcsr_meta_size, dbcsr_num_slots, dbcsr_slot_blk_p, &
      dbcsr_slot_col_i, dbcsr_slot_dense, dbcsr_slot_home_coli, dbcsr_slot_home_pcol, &
      dbcsr_slot_home_prow, dbcsr_slot_home_rowi, dbcsr_slot_home_vpcol, dbcsr_slot_home_vprow, &
      dbcsr_slot_nblkcols_local, dbcsr_slot_nblkcols_total, dbcsr_slot_nblkrows_local, &
      dbcsr_slot_nblkrows_total, dbcsr_slot_nblks, dbcsr_slot_nfullcols_local, &
      dbcsr_slot_nfullcols_total, dbcsr_slot_nfullrows_local, dbcsr_slot_nfullrows_total, &
      dbcsr_slot_nze, dbcsr_slot_row_p, dbcsr_slot_type, dbcsr_type, dbcsr_type_complex_4, &
      dbcsr_type_complex_8, dbcsr_type_real_4, dbcsr_type_real_8
#include "base/dbcsr_base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_dist_util'

   ! Main
   PUBLIC :: dbcsr_checksum, dbcsr_verify_matrix, &
             dbcsr_pack_meta, dbcsr_unpack_meta, meta_from_dist
   ! Block sizes and arrays
   PUBLIC :: convert_sizes_to_offsets, convert_offsets_to_sizes, &
             global_offsets_to_local, &
             nfull_elements, &
             dbcsr_calc_block_sizes, &
             find_block_of_element, &
             get_internal_offsets, &
             map_most_common
   ! utility routines
   PUBLIC :: count_bins, sgn

   LOGICAL, PARAMETER :: bcsr_info = .FALSE.
   LOGICAL, PARAMETER :: bcsr_verbose = .FALSE.

CONTAINS

   SUBROUTINE find_block_of_element(full, block, nblocks, &
                                    block_offsets, hint)
      !! Finds block to which a full element belongs.
      !!
      !! Assumptions
      !! It is assumed that block_start and block_end are sorted and
      !! that hint is in the range [0, nblocks].

      INTEGER, INTENT(in)                                :: full
         !! full element
      INTEGER, INTENT(out)                               :: block
         !! block to which full belongs
      INTEGER, INTENT(in)                                :: nblocks
      INTEGER, DIMENSION(1:nblocks + 1), INTENT(in)        :: block_offsets
         !! starting full elements of blocks
      INTEGER, INTENT(in)                                :: hint
         !! where to start looking; ignored if 0

      LOGICAL, PARAMETER                                 :: dbg = .FALSE.

      INTEGER                                            :: count

      IF (hint .NE. 0) THEN
         block = hint
      ELSE
         block = MAX(1, (nblocks + 1)/2)
      END IF
      count = 0
      DO WHILE (block_offsets(block) .GT. full .OR. block_offsets(block + 1) - 1 .LT. full)
         IF (block_offsets(block) .GT. full) THEN
            block = block - 1
         ELSEIF (block_offsets(block + 1) - 1 .LT. full) THEN
            block = block + 1
         END IF
         count = count + 1
         IF (dbg) THEN
            IF (count .GT. nblocks .OR. block .LT. 1 .OR. block .GT. nblocks) THEN
               WRITE (*, '(1X,A,I9,A,I9,A)') "Want to find block", &
                  block, " of", nblocks, " blocks"
               IF (count .GT. nblocks) &
                  DBCSR_ABORT("Too many searches")
            END IF
         END IF
      END DO
   END SUBROUTINE find_block_of_element

   PURE FUNCTION nfull_elements(all_offsets, local_elements)
      !! The sum of a subset of rows/columns
      !! \return sum of sizes of local elements
      !! @note Used for making matrices dense/undense

      INTEGER, DIMENSION(:), INTENT(IN)                  :: all_offsets, local_elements
         !! ordered offsets of all the elements
         !! enumerated local elements
      INTEGER                                            :: nfull_elements

      INTEGER                                            :: el, lel

      nfull_elements = 0
      DO lel = 1, SIZE(local_elements)
         el = local_elements(lel)
         nfull_elements = nfull_elements + all_offsets(el + 1) - all_offsets(el)
      END DO
   END FUNCTION nfull_elements

   PURE SUBROUTINE convert_sizes_to_offsets(sizes, &
                                            offsets_start, offsets_stop)
      !! Converts sizes to offsets

      INTEGER, DIMENSION(:), INTENT(IN)                  :: sizes
         !! array with sizes
      INTEGER, DIMENSION(:), INTENT(OUT)                 :: offsets_start
         !! offsets of starts
      INTEGER, DIMENSION(:), INTENT(OUT), OPTIONAL       :: offsets_stop
         !! offsets of ends

      INTEGER                                            :: i, n

!   ---------------------------------------------------------------------------

      n = SIZE(sizes)
      IF (n .GT. 0) THEN
         offsets_start(1) = 1
         IF (PRESENT(offsets_stop)) offsets_stop(1) = sizes(1)
         IF (.NOT. PRESENT(offsets_stop)) THEN
            DO i = 2, n
               offsets_start(i) = offsets_start(i - 1) + sizes(i - 1)
            END DO
            IF (SIZE(offsets_start) .GT. n) &
               offsets_start(n + 1) = offsets_start(n) + sizes(n)
         ELSE
            DO i = 2, n
               offsets_start(i) = offsets_start(i - 1) + sizes(i - 1)
               offsets_stop(i) = offsets_stop(i - 1) + sizes(i)
            END DO
            IF (SIZE(offsets_start) .GT. n) &
               offsets_start(n + 1) = offsets_start(n) + sizes(n)
         END IF
      ELSE
         IF (.NOT. PRESENT(offsets_stop)) THEN
            offsets_start(1) = 0
         END IF
      END IF
   END SUBROUTINE convert_sizes_to_offsets

   PURE SUBROUTINE convert_offsets_to_sizes(offsets_start, sizes, offsets_stop)
      !! Converts offsets to sizes
      !! If the offsets of ends are not given, then the array of sizes is assumed
      !! to be one greater than the desired sizes.

      INTEGER, DIMENSION(:), INTENT(IN)                  :: offsets_start
         !! offsets of starts
      INTEGER, DIMENSION(:), INTENT(OUT)                 :: sizes
         !! array with sizes
      INTEGER, DIMENSION(:), INTENT(IN), OPTIONAL        :: offsets_stop
         !! offsets of ends

      INTEGER                                            :: i, n

!   ---------------------------------------------------------------------------

      n = SIZE(offsets_start)
      IF (PRESENT(offsets_stop)) THEN
         sizes(:) = offsets_stop(:) - offsets_start(:) + 1
      ELSE
         IF (n .GT. 1) THEN
            DO i = 1, n - 1
               sizes(i) = sizes(i + 1) - sizes(i)
            END DO
         END IF
      END IF
   END SUBROUTINE convert_offsets_to_sizes

   SUBROUTINE global_offsets_to_local(global_offsets, &
                                      local_elements, local_offsets)
      !! Converts global offsets to local
      !!
      !! Global vs. Local Indexing
      !! local_offsets may be sized according to the
      !! local index (|local_elements+|1) or the
      !! global index (|global_offsets|).

      INTEGER, DIMENSION(:), INTENT(IN)                  :: global_offsets, local_elements
         !! Offsets of elements in the global grid
         !! Which elements are local
      INTEGER, DIMENSION(:), INTENT(OUT)                 :: local_offsets
         !! Offsets of local elements.

      INTEGER                                            :: acc, el, lel, nglobal, nlo, nlocal, &
                                                            prev_el, sz
      LOGICAL                                            :: local

!   ---------------------------------------------------------------------------

      nglobal = SIZE(global_offsets) - 1
      nlocal = SIZE(local_elements)
      nlo = SIZE(local_offsets) - 1
      local = .NOT. (nglobal .EQ. nlo)
      IF (local) THEN
         IF (nlocal /= nlo) &
            DBCSR_ABORT("Invalid size for local offsets")
      END IF
      IF (local) THEN
         acc = 1
         DO lel = 1, nlocal
            local_offsets(lel) = acc
            el = local_elements(lel)
            sz = global_offsets(el + 1) - global_offsets(el)
            acc = acc + sz
         END DO
         local_offsets(nlocal + 1) = acc
      ELSE
         acc = 1
         prev_el = 0
         DO lel = 1, nlocal
            el = local_elements(lel)
            local_offsets(prev_el + 1:el) = acc
            sz = global_offsets(el + 1) - global_offsets(el)
            acc = acc + sz
            prev_el = el
         END DO
         local_offsets(prev_el + 1:nglobal + 1) = acc
      END IF
   END SUBROUTINE global_offsets_to_local

   SUBROUTINE get_internal_offsets(blk_local_els, el_map, blk_el_offsets, &
                                   dense_el_offsets, internal_offsets)
      !! Finds internal offsets
      !! For all local blocks in blk_local_els, it calculates its offset in
      !! the dense block to which it belongs.

      INTEGER, DIMENSION(:), INTENT(IN)                  :: blk_local_els, el_map, blk_el_offsets, &
                                                            dense_el_offsets
      INTEGER, DIMENSION(:), INTENT(OUT)                 :: internal_offsets

      INTEGER                                            :: blk_el, d_el, i, ndense, nlblk
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: off_acc

!   ---------------------------------------------------------------------------

      nlblk = SIZE(blk_local_els)
      ndense = SIZE(dense_el_offsets)
      ALLOCATE (off_acc(ndense))
      off_acc(:) = 0
      internal_offsets(:) = 0
      DO i = 1, nlblk
         blk_el = blk_local_els(i)
         d_el = el_map(blk_el)
         internal_offsets(blk_el) = off_acc(d_el)
         off_acc(d_el) = off_acc(d_el) + blk_el_offsets(blk_el + 1) - blk_el_offsets(blk_el)
      END DO
      DEALLOCATE (off_acc)
   END SUBROUTINE get_internal_offsets

   SUBROUTINE dbcsr_calc_block_sizes(sizes, row_p, col_i, rbs, cbs)
      !! Calculates explicit sizes for all data blocks.

      INTEGER, DIMENSION(*), INTENT(OUT)                 :: sizes
         !! sizes of all data blocks
      INTEGER, DIMENSION(:), INTENT(IN)                  :: row_p
         !! index structure
      INTEGER, DIMENSION(*), INTENT(IN)                  :: col_i, rbs, cbs
         !! index structure
         !! row block sizes
         !! column block sizes

      INTEGER                                            :: blk, nrows, row, row_size

      nrows = SIZE(row_p) - 1
!$OMP     DO
      DO row = 1, nrows
         row_size = rbs(row)
         DO blk = row_p(row) + 1, row_p(row + 1)
            sizes(blk) = row_size*cbs(col_i(blk))
         END DO
      END DO
!$OMP     END DO
   END SUBROUTINE dbcsr_calc_block_sizes

   ELEMENTAL FUNCTION sgn(n, oldsign, x) RESULT(val)
      INTEGER, INTENT(IN)                                :: n, oldsign
      LOGICAL, INTENT(IN)                                :: x
      INTEGER                                            :: val

      IF (.NOT. x) THEN
         val = SIGN(n, oldsign)
      ELSE
         val = -SIGN(n, oldsign)
      END IF
   END FUNCTION sgn

   SUBROUTINE meta_from_dist(meta, dist, row_blk_size, col_blk_size)
      !! Fills meta information from a given distribution_2d

      INTEGER, DIMENSION(dbcsr_meta_size), INTENT(OUT)   :: meta
         !! meta information array to fill
      TYPE(dbcsr_distribution_obj), INTENT(IN)           :: dist
         !! processor distribution
      INTEGER, DIMENSION(:), INTENT(IN), POINTER         :: row_blk_size, col_blk_size
         !! row block sizes
         !! column block sizes

      INTEGER                                            :: i, nfullcols_local, nfullcols_total, &
                                                            nfullrows_local, nfullrows_total
      INTEGER, DIMENSION(:), POINTER                     :: blkcols_local, blkrows_local

!   ---------------------------------------------------------------------------

      blkrows_local => dbcsr_distribution_local_rows(dist)
      blkcols_local => dbcsr_distribution_local_cols(dist)
      nfullrows_total = SUM(row_blk_size)
      nfullcols_total = SUM(col_blk_size)
      nfullrows_local = 0
      nfullcols_local = 0
      DO i = 1, dbcsr_distribution_nlocal_rows(dist)
         nfullrows_local = nfullrows_local + row_blk_size(blkrows_local(i))
      END DO
      DO i = 1, dbcsr_distribution_nlocal_cols(dist)
         nfullcols_local = nfullcols_local + col_blk_size(blkcols_local(i))
      END DO
      meta(:) = 0
      meta(5) = dbcsr_distribution_nrows(dist)
      meta(6) = dbcsr_distribution_ncols(dist)
      meta(7) = nfullrows_total
      meta(8) = nfullcols_total
      meta(9) = dbcsr_distribution_nlocal_rows(dist)
      meta(10) = dbcsr_distribution_nlocal_cols(dist)
      meta(11) = nfullrows_local
      meta(12) = nfullcols_local
      meta(dbcsr_slot_home_prow) = dbcsr_mp_myprow(dbcsr_distribution_mp(dist))
      meta(dbcsr_slot_home_rowi) = 1
      meta(dbcsr_slot_home_pcol) = dbcsr_mp_mypcol(dbcsr_distribution_mp(dist))
      meta(dbcsr_slot_home_coli) = 1
      meta(dbcsr_slot_home_vprow) = -1
      meta(dbcsr_slot_home_vpcol) = -1
   END SUBROUTINE meta_from_dist

   SUBROUTINE dbcsr_pack_meta(matrix, meta)
      !! Copies metadata into an array.

      TYPE(dbcsr_type), INTENT(IN)                       :: matrix
         !! Matrix
      INTEGER, DIMENSION(dbcsr_meta_size), INTENT(OUT)   :: meta
         !! Metadata elements

!   ---------------------------------------------------------------------------

      meta(dbcsr_slot_nblks) = matrix%nblks
      meta(dbcsr_slot_nze) = matrix%nze
      meta(dbcsr_slot_nblkrows_total) = matrix%nblkrows_total
      meta(dbcsr_slot_nblkcols_total) = matrix%nblkcols_total
      meta(dbcsr_slot_nfullrows_total) = matrix%nfullrows_total
      meta(dbcsr_slot_nfullcols_total) = matrix%nfullcols_total
      meta(dbcsr_slot_nblkrows_local) = matrix%nblkrows_local
      meta(dbcsr_slot_nblkcols_local) = matrix%nblkcols_local
      meta(dbcsr_slot_nfullrows_local) = matrix%nfullrows_local
      meta(dbcsr_slot_nfullcols_local) = matrix%nfullcols_local
      meta(dbcsr_slot_dense) = 0
      meta(dbcsr_slot_type) = 0
      !IF (matrix%transpose)&
      !     meta(dbcsr_slot_type) = IBSET (meta(dbcsr_slot_type), 0)
      IF (matrix%symmetry) &
         meta(dbcsr_slot_type) = IBSET(meta(dbcsr_slot_type), 1)
      IF (matrix%negate_real) &
         meta(dbcsr_slot_type) = IBSET(meta(dbcsr_slot_type), 2)
      IF (matrix%negate_imaginary) &
         meta(dbcsr_slot_type) = IBSET(meta(dbcsr_slot_type), 3)
   END SUBROUTINE dbcsr_pack_meta

   SUBROUTINE dbcsr_unpack_meta(matrix, meta)
      !! Sets metadata form an array.

      TYPE(dbcsr_type), INTENT(INOUT)                    :: matrix
         !! Matrix
      INTEGER, DIMENSION(dbcsr_meta_size), INTENT(IN)    :: meta
         !! Metadata elements

!   ---------------------------------------------------------------------------

      matrix%nblks = meta(dbcsr_slot_nblks)
      matrix%nze = meta(dbcsr_slot_nze)
      matrix%nblkrows_total = meta(dbcsr_slot_nblkrows_total)
      matrix%nblkcols_total = meta(dbcsr_slot_nblkcols_total)
      matrix%nfullrows_total = meta(dbcsr_slot_nfullrows_total)
      matrix%nfullcols_total = meta(dbcsr_slot_nfullcols_total)
      matrix%nblkrows_local = meta(dbcsr_slot_nblkrows_local)
      matrix%nblkcols_local = meta(dbcsr_slot_nblkcols_local)
      matrix%nfullrows_local = meta(dbcsr_slot_nfullrows_local)
      matrix%nfullcols_local = meta(dbcsr_slot_nfullcols_local)
      matrix%index(dbcsr_slot_dense) = 0
      !matrix%transpose = BTEST (meta(dbcsr_slot_type), 0)
      matrix%symmetry = BTEST(meta(dbcsr_slot_type), 1)
      matrix%negate_real = BTEST(meta(dbcsr_slot_type), 2)
      matrix%negate_imaginary = BTEST(meta(dbcsr_slot_type), 3)
   END SUBROUTINE dbcsr_unpack_meta

   FUNCTION dbcsr_checksum(matrix, local, pos) RESULT(checksum)
      !! Calculates the checksum of a DBCSR matrix.

      TYPE(dbcsr_type), INTENT(IN)                       :: matrix
         !! matrix
      LOGICAL, INTENT(IN), OPTIONAL                      :: local, pos
         !! no global communication
         !! position-dependent checksum
      REAL(KIND=dp)                                      :: checksum
         !! calculated checksum

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_checksum'
      COMPLEX(KIND=real_4), DIMENSION(:), POINTER        :: c_sp
      COMPLEX(KIND=real_8), DIMENSION(:), POINTER        :: c_dp
      INTEGER                                            :: bc, blk, blk_p, br, co, handle, m, mn, &
                                                            n, ro
      INTEGER, DIMENSION(:), POINTER                     :: col_blk_size, row_blk_size
      LOGICAL                                            :: nocomm, pd, tr
      REAL(KIND=dp)                                      :: blk_cs, local_cs, local_cs_row
      REAL(KIND=real_4), DIMENSION(:), POINTER           :: r_sp
      REAL(KIND=real_8), DIMENSION(:), POINTER           :: r_dp

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, handle)
      IF (.NOT. dbcsr_valid_index(matrix)) &
         DBCSR_ABORT("Invalid matrix.")
      nocomm = .FALSE.
      IF (PRESENT(local)) nocomm = local
      IF (PRESENT(pos)) THEN
         pd = pos
      ELSE
         pd = .FALSE.
      END IF
      row_blk_size => array_data(matrix%row_blk_size)
      col_blk_size => array_data(matrix%col_blk_size)
      local_cs = 0.0_dp
      SELECT CASE (matrix%data_type)
      CASE (dbcsr_type_real_8)
         CALL dbcsr_get_data(matrix%data_area, r_dp)
      CASE (dbcsr_type_real_4)
         CALL dbcsr_get_data(matrix%data_area, r_sp)
      CASE (dbcsr_type_complex_8)
         CALL dbcsr_get_data(matrix%data_area, c_dp)
      CASE (dbcsr_type_complex_4)
         CALL dbcsr_get_data(matrix%data_area, c_sp)
      END SELECT
      DO br = 1, matrix%nblkrows_total
         m = row_blk_size(br)
         ro = dbcsr_blk_row_offset(matrix, br)
         local_cs_row = 0
!$OMP        PARALLEL DO DEFAULT(NONE) &
!$OMP                 PRIVATE(bc,m,n,mn,blk_p,blk_cs,tr,co) &
!$OMP                 SHARED(pd,br,matrix,ro,row_blk_size,col_blk_size,r_dp, r_sp, c_dp,c_sp) &
!$OMP                  REDUCTION(+:local_cs_row)
         DO blk = matrix%row_p(br) + 1, matrix%row_p(br + 1)
            bc = matrix%col_i(blk)
            m = row_blk_size(br)
            n = col_blk_size(bc)
            mn = m*n
            blk_p = ABS(matrix%blk_p(blk))
            tr = matrix%blk_p(blk) .LT. 0
            IF (blk_p .NE. 0) THEN
               IF (mn .GT. 0) THEN
                  IF (tr) CALL swap(m, n)
                  co = dbcsr_blk_col_offset(matrix, bc)
                  ! Calculate DDOT
                  SELECT CASE (matrix%data_type)
                  CASE (dbcsr_type_real_8)
                     IF (pd) THEN
                        blk_cs = pd_blk_cs(m, n, r_dp(blk_p:blk_p + mn - 1), &
                                           tr, ro, co)
                     ELSE
                        blk_cs = REAL(DOT_PRODUCT(r_dp(blk_p:blk_p + mn - 1), &
                                                  r_dp(blk_p:blk_p + mn - 1)), KIND=dp)
                     END IF
                  CASE (dbcsr_type_real_4)
                     IF (pd) THEN
                        blk_cs = pd_blk_cs(m, n, REAL(r_sp(blk_p:blk_p + mn - 1), KIND=dp), &
                                           tr, ro, co)
                     ELSE
                        blk_cs = REAL(DOT_PRODUCT(r_sp(blk_p:blk_p + mn - 1), &
                                                  r_sp(blk_p:blk_p + mn - 1)), KIND=dp)
                     END IF
                  CASE (dbcsr_type_complex_8)
                     IF (pd) THEN
                        blk_cs = pd_blk_cs(m, n, REAL(c_dp(blk_p:blk_p + mn - 1), KIND=dp), &
                                           tr, ro, co)
                     ELSE
                        blk_cs = REAL(DOT_PRODUCT(c_dp(blk_p:blk_p + mn - 1), &
                                                  c_dp(blk_p:blk_p + mn - 1)), KIND=dp)
                     END IF
                  CASE (dbcsr_type_complex_4)
                     IF (pd) THEN
                        blk_cs = pd_blk_cs(m, n, REAL(c_sp(blk_p:blk_p + mn - 1), KIND=dp), &
                                           tr, ro, co)
                     ELSE
                        blk_cs = REAL(DOT_PRODUCT(c_sp(blk_p:blk_p + mn - 1), &
                                                  c_sp(blk_p:blk_p + mn - 1)), KIND=dp)
                     END IF
                  CASE default
                     blk_cs = 0.0_dp
                  END SELECT
               ELSE
                  blk_cs = 0.0_dp
               END IF
               local_cs_row = local_cs_row + blk_cs
            END IF
         END DO
         local_cs = local_cs + local_cs_row
      END DO
      checksum = local_cs
      IF (.NOT. nocomm) THEN
         CALL mp_sum(local_cs, dbcsr_mp_group(dbcsr_distribution_mp( &
                                              matrix%dist)))
         checksum = local_cs
      END IF
      CALL timestop(handle)
   END FUNCTION dbcsr_checksum

   PURE FUNCTION pd_blk_cs(ld, od, DATA, tr, ro, co) RESULT(pd_cs)
      INTEGER, INTENT(IN)                                :: ld, od
      REAL(KIND=dp), DIMENSION(ld, od), INTENT(IN)       :: DATA
      LOGICAL, INTENT(IN)                                :: tr
      INTEGER, INTENT(IN)                                :: ro, co
      REAL(KIND=dp)                                      :: pd_cs

      INTEGER                                            :: c, cs, r, rs

      pd_cs = 0.0_dp
      rs = ld; cs = od
      IF (tr) THEN
         CALL swap(rs, cs)
         DO r = 1, rs
            DO c = 1, cs
               pd_cs = pd_cs + DATA(c, r)*LOG(ABS(REAL((ro + r - 1), KIND=dp)*REAL((co + c - 1), KIND=dp)))
            END DO
         END DO
      ELSE
         DO c = 1, cs
            DO r = 1, rs
               pd_cs = pd_cs + DATA(r, c)*LOG(ABS(REAL((ro + r - 1), KIND=dp)*REAL((co + c - 1), KIND=dp)))
            END DO
         END DO
      END IF
   END FUNCTION pd_blk_cs

   SUBROUTINE dbcsr_verify_matrix(m, verbosity, local)
      !! Verify the correctness of a BCSR matrix.

      TYPE(dbcsr_type), INTENT(IN)                       :: m
         !! bcsr matrix
      INTEGER, INTENT(IN), OPTIONAL                      :: verbosity
         !! how detailed errors are; 0=nothing; 1=summary at end if matrix not consistent; 2=also individual errors; 3=always print
         !! info about matrix; >3=even more info
      LOGICAL, INTENT(IN), OPTIONAL                      :: local
         !! no global communication

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_verify_matrix', r = moduleN//':'//routineN

      INTEGER                                            :: bc, blk, blk_p, br, &
                                                            data_size_referenced, dbg, handle, i, &
                                                            mb, mn, n, n_have_blocks_local, &
                                                            n_have_blocks_total, prev_br
      INTEGER(KIND=int_8)                                :: n_full_blocks_total
      INTEGER, DIMENSION(:), POINTER                     :: col_blk_size, row_blk_size
      LOGICAL                                            :: nocomm
      REAL(KIND=dp)                                      :: sparsity_total

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, handle)
      dbg = 2
      nocomm = .FALSE.
      IF (PRESENT(local)) nocomm = local
      IF (PRESENT(verbosity)) dbg = verbosity
      IF (dbg .GE. 3) WRITE (*, '(1X,A,A,A,3(L1))') r//'Matrix name: ', m%name, &
         " of types ", m%symmetry, m%negate_real, &
         m%negate_imaginary
      IF (dbg .GE. 3) THEN
         WRITE (*, '(1X,A,I5,"x",I5,A,I5,"x",I5)') r//' Size blocked', &
            m%nblkrows_total, m%nblkcols_total, ", full ", &
            m%nfullrows_total, m%nfullcols_total
      END IF
      row_blk_size => array_data(m%row_blk_size)
      col_blk_size => array_data(m%col_blk_size)
      !
      IF (.NOT. dbcsr_has_symmetry(m)) THEN
         n_full_blocks_total = INT(m%nblkrows_total, KIND=int_8)*INT(m%nblkcols_total, KIND=int_8)
      ELSE
         IF (m%nblkrows_total /= m%nblkcols_total) &
            DBCSR_ABORT('Symmetric matrix is not square')
         n_full_blocks_total = INT(m%nblkrows_total, KIND=int_8)*(m%nblkrows_total + 1)/2
      END IF
      n_have_blocks_local = m%nblks
2045  FORMAT(I5, 1X, I5, 1X, I5, 1X, I5, 1X, I5, 1X, I5, 1X, I5, 1X, I5, 1X, I5, 1X, I5)
2047  FORMAT(I7, 1X, I7, 1X, I7, 1X, I7, 1X, I7, 1X, I7, 1X, I7, 1X, I7, 1X, I7, 1X, I7)
      IF (dbg .GE. 4) THEN
         WRITE (*, '(1X,A)') r//' index='
         WRITE (*, 2045) m%index(:dbcsr_num_slots)
      END IF
      IF (m%index(1) .LE. 0) &
         DBCSR_ABORT('Index size 0')
      DO i = dbcsr_slot_row_p, dbcsr_num_slots
         !IF(m%index(i) .LE. 0) &
         !   DBCSR_ABORT('Index member is 0')
         IF (.NOT. (i .EQ. dbcsr_slot_col_i .OR. i .EQ. dbcsr_slot_blk_p)) THEN
            IF (m%index(i) > m%index(1)) &
               DBCSR_ABORT('Index member is greater than size')
         END IF
      END DO
      !
      IF (dbg .GE. 4) WRITE (*, *) r//' row_p extents', m%index(dbcsr_slot_row_p + 1), &
         m%index(dbcsr_slot_row_p), SIZE(m%row_p)
      IF (m%index(dbcsr_slot_row_p + 1) - m%index(dbcsr_slot_row_p) + 1 /= m%nblkrows_total + 1) &
         DBCSR_ABORT('Size of row_p index inconsistent with number of rows')
      IF (SIZE(m%row_p) /= m%nblkrows_total + 1) &
         DBCSR_ABORT('Size of row_p inconsistent with number of rows')
      !
      IF (dbg .GE. 4) WRITE (*, *) r//' col_i extents', m%index(dbcsr_slot_col_i + 1), &
         m%index(dbcsr_slot_col_i), SIZE(m%col_i)
      IF (m%index(dbcsr_slot_col_i + 1) - m%index(dbcsr_slot_col_i) + 1 /= m%nblks) &
         DBCSR_ABORT('Size of col_i index inconsistent with number of blocks')
      IF (SIZE(m%col_i) /= m%nblks) &
         DBCSR_ABORT('Size of col inconsistent with number of blocks')
      !
      IF (dbg .GE. 4) WRITE (*, *) r//' blk_p extents', m%index(dbcsr_slot_blk_p + 1), &
         m%index(dbcsr_slot_blk_p), SIZE(m%blk_p)
      IF (m%index(dbcsr_slot_blk_p + 1) - m%index(dbcsr_slot_blk_p) + 1 /= m%nblks) &
         DBCSR_ABORT('Size of blk_p index inconsistent with number of blocks')
      IF (SIZE(m%col_i) /= m%nblks) &
         DBCSR_ABORT('Size of blk_p inconsistent with number of blocks')
      !
      IF (SIZE(row_blk_size) /= m%nblkrows_total) &
         DBCSR_ABORT('Row block size array inconsistent with number of blocked rows')
      IF (SIZE(col_blk_size) /= m%nblkcols_total) &
         DBCSR_ABORT('Column block size array inconsistent with number of blocked columns')
      !
      IF (dbg .GE. 4) THEN
         WRITE (*, '(1X,A,I7,A,I7)') r//' nze=', m%nze, 'data size', &
            dbcsr_data_get_size(m%data_area)
      END IF
      data_size_referenced = dbcsr_data_get_size_referenced(m%data_area)
      !This tends to be too verbose and usually untrue for symmetric
      !matrices.
      !IF(dbcsr_get_data_size(m%data_area) < m%nze) &
      !   DBCSR_ABORT('Data storage may be too small.')
      IF (dbg .GE. 5) THEN
         WRITE (*, '(1X,A,I7,A)') r//' size=', SIZE(m%row_p), ' row_p='
         WRITE (*, 2047) m%row_p(1:m%nblkrows_total + 1)
         WRITE (*, '(1X,A)') r//' col_i='
         WRITE (*, 2047) m%col_i(1:m%nblks)
         WRITE (*, '(1X,A)') r//' blk_p='
         WRITE (*, 2047) m%blk_p(1:m%nblks)
      END IF
      prev_br = 0
      DO br = 1, m%nblkrows_total
         IF (m%row_p(br) < 0) DBCSR_ABORT('row_p less than zero')
         IF (br .GT. 1) THEN
            IF (m%row_p(br) < m%row_p(prev_br)) DBCSR_ABORT('row_p decreases')
         END IF
         mb = row_blk_size(br)
         IF (mb < 0) &
            DBCSR_ABORT('Row blocked size is negative')
         DO blk = m%row_p(br) + 1, m%row_p(br + 1)
            IF (blk < 0) DBCSR_ABORT('Block number is zero')
            IF (blk > m%nblks) DBCSR_ABORT('Block number too high')
            bc = m%col_i(blk)
            IF (dbg .GE. 5) THEN
               WRITE (*, '(1X,A,I7,"(",I5,",",I5,")")') r//' block', blk, br, bc
            END IF
            IF (bc .LE. 0) DBCSR_ABORT('col_i is zero')
            IF (bc > m%nblkcols_total) DBCSR_ABORT('col_i too high')
            n = col_blk_size(bc)
            IF (n < 0) DBCSR_ABORT('Column blocked size is negative')
            blk_p = m%blk_p(blk)
            mn = mb*n
            !IF(blk_p.LE.0) DBCSR_ABORT('Block pointer is negative')
            !IF(blk_p > m%nze) &
            !   DBCSR_ABORT('Block pointer too large')
            !IF(blk_p+mn-1 > m%nze) &
            !   DBCSR_ABORT('Block extends too far')
            IF (mn .GT. 0 .AND. ABS(blk_p) > data_size_referenced) &
               DBCSR_ABORT("Block pointer pointso outside of declared referenced area")
            IF (ABS(blk_p) + mn - 1 > data_size_referenced) &
               DBCSR_ABORT("Block extends outside of declared referenced area")
         END DO
         prev_br = br
      END DO
      IF (dbg .GE. 3 .AND. .NOT. nocomm) THEN
         CALL mp_sum(n_have_blocks_local, dbcsr_mp_group(dbcsr_distribution_mp( &
                                                         m%dist)))
         n_have_blocks_total = n_have_blocks_local
         sparsity_total = REAL(n_have_blocks_total, KIND=dp) &
                          /REAL(n_full_blocks_total, KIND=dp)*100.0_dp
         !WRITE(*,FMT='(30A,F5.1,A)')r//' Sparsity: ', sparsity_total,'%'
         WRITE (*, FMT='(1X,A,F5.1,A)') r//' Non-sparsity: ', &
            sparsity_total, '%'
      END IF

      CALL timestop(handle)
   END SUBROUTINE dbcsr_verify_matrix

   PURE SUBROUTINE count_bins(nelements, bins, nbins, bin_counts)
      INTEGER, INTENT(IN)                                :: nelements
      INTEGER, DIMENSION(:), INTENT(IN)                  :: bins
      INTEGER, INTENT(IN)                                :: nbins
      INTEGER, DIMENSION(1:nbins), INTENT(OUT)           :: bin_counts

      INTEGER                                            :: bin, i, i0, i1

      ! PURE: DBCSR_ASSERT(nelements .EQ. SIZE(bins))
      bin_counts(:) = 0
      i0 = LBOUND(bins, 1)
      i1 = i0 + nelements - 1
      DO i = i0, i1
         bin = bins(i)
         bin_counts(bin) = bin_counts(bin) + 1
      END DO
   END SUBROUTINE count_bins

   SUBROUTINE map_most_common(array, most_common_map, nmost_common, &
                              most_common_elements, size_limit, max_val)
      !! Makes a lookup table from the most common elements.
      !!
      !! Lookup table
      !! The lookup table is indexed by the most common array values
      !! (i.e., block sizes).  Its values are the order of their frequency.

      INTEGER, DIMENSION(:), INTENT(IN)                  :: array
         !! Array for which to find the most common elements.
      INTEGER(KIND=int_4), DIMENSION(:), POINTER         :: most_common_map
         !! Ranking of the most common elements in array
      INTEGER, INTENT(IN)                                :: nmost_common
         !! The number of most common elements
      INTEGER, DIMENSION(:), INTENT(OUT)                 :: most_common_elements
         !! The most common elements in array
      INTEGER, INTENT(IN)                                :: size_limit
         !! Limit maximum size to this value
      INTEGER, INTENT(OUT)                               :: max_val

      INTEGER                                            :: i, max_val_l, nmc
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: permutation, size_counts

!   ---------------------------------------------------------------------------

      IF (SIZE(array) .GT. 0) THEN
         max_val = MAXVAL(array)
         max_val_l = MIN(MIN(size_limit, max_val), INT(HUGE(most_common_map)))
      ELSE
         max_val = 0
         max_val_l = 0
      END IF
      ! Count the frequency of all block sizes up to max_val_l.
      ALLOCATE (size_counts(0:max_val_l))
      ALLOCATE (permutation(0:max_val_l))
      size_counts = 0
      permutation = 0
      DO i = 1, SIZE(array)
         ! Counts are decreased to easily get a reverse sort order.
         IF (array(i) .LE. max_val_l) &
            size_counts(array(i)) = size_counts(array(i)) - 1
      END DO
      IF (SIZE(array) .GT. 0) THEN
         CALL sort(size_counts, max_val_l + 1, permutation)
      END IF
      ! Limiting nmc to max_val_l prevents out-of-bounds.
      nmc = MIN(nmost_common, max_val_l)
      ! Determine the biggest block size and allocate the map.
      ALLOCATE (most_common_map(0:max_val_l))
      ! Create the mapping from block size to order.
      most_common_map = nmost_common + 1
      DO i = 1, nmc
         most_common_map(permutation(i - 1) - 1) = i
      END DO
      ! Copy the most common elements
      most_common_elements(:) = 0
      most_common_elements(1:nmc) = permutation(0:nmc - 1) - 1
      DEALLOCATE (size_counts)
      DEALLOCATE (permutation)
   END SUBROUTINE map_most_common

END MODULE dbcsr_dist_util
