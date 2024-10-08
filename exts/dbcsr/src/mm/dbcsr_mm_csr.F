!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_mm_csr
   !! Third layer of the dbcsr matrix-matrix multiplication.
   !! It collects the full matrix blocks, which need to be multiplied,
   !! and stores their parameters in various stacks.
   !! After a certain amount of parameters is collected it dispatches
   !! the filled stacks to either the CPU or the accelerator device.
   !! <b>Modification history:</b>
   !! - 2010-02-23 Moved from dbcsr_operations
   !! - 2011-11    Moved parameter-stack processing routines to
   !! dbcsr_mm_methods.
   !! - 2013-01    extensive refactoring (Ole Schuett)

   USE dbcsr_array_types, ONLY: array_data
   USE dbcsr_block_operations, ONLY: block_add, &
                                     dbcsr_block_copy_aa
   USE dbcsr_config, ONLY: dbcsr_cfg, &
                           default_resize_factor
   USE dbcsr_data_methods, ONLY: dbcsr_data_ensure_size
   USE dbcsr_dist_util, ONLY: map_most_common
   USE dbcsr_kinds, ONLY: int_1, &
                          int_4, &
                          int_8, &
                          sp
   USE dbcsr_mm_sched, ONLY: &
      dbcsr_mm_sched_barrier, dbcsr_mm_sched_begin_burst, dbcsr_mm_sched_dev2host_init, &
      dbcsr_mm_sched_end_burst, dbcsr_mm_sched_finalize, dbcsr_mm_sched_init, &
      dbcsr_mm_sched_lib_finalize, dbcsr_mm_sched_lib_init, &
      dbcsr_mm_sched_process, dbcsr_mm_sched_set_orig_datasize, dbcsr_mm_sched_type
   USE dbcsr_mm_types, ONLY: &
      dbcsr_ps_width, p_a_first, p_b_first, p_c_blk, p_c_first, p_k, p_m, p_n, &
      stack_descriptor_type
   USE dbcsr_ptr_util, ONLY: ensure_array_size
   USE dbcsr_toollib, ONLY: sort
   USE dbcsr_types, ONLY: dbcsr_data_obj, &
                          dbcsr_type, &
                          dbcsr_work_type
#include "base/dbcsr_base_uses.f90"

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_mm_csr'
   LOGICAL, PARAMETER :: debug_mod = .FALSE.
   LOGICAL, PARAMETER :: careful_mod = .FALSE.

   INTEGER, PARAMETER :: max_stack_block_size = HUGE(INT(0))
      !!  max_stack_block_size  The maximal block size to be specially treated.

! **************************************************************************************************
   TYPE dbcsr_mm_csr_type
      PRIVATE
      TYPE(hash_table_type), DIMENSION(:), POINTER  :: c_hashes => Null()
      INTEGER                        :: nm_stacks = -1, nn_stacks = -1, nk_stacks = -1
      INTEGER(KIND=int_4), DIMENSION(:), POINTER :: m_size_maps => Null()
      INTEGER(KIND=int_4), DIMENSION(:), POINTER :: n_size_maps => Null()
      INTEGER(KIND=int_4), DIMENSION(:), POINTER :: k_size_maps => Null()
      INTEGER                        :: max_m = -1, max_n = -1, max_k = -1
      INTEGER                        :: m_size_maps_size = -1, &
                                        n_size_maps_size = -1, &
                                        k_size_maps_size = -1
      INTEGER(KIND=int_1), DIMENSION(:, :, :), POINTER :: stack_map => Null()
      TYPE(stack_descriptor_type), DIMENSION(:), POINTER  :: stacks_descr => Null()
      TYPE(dbcsr_work_type), POINTER           :: product_wm => Null()
      INTEGER, DIMENSION(:, :, :), POINTER       :: stacks_data => Null()
      INTEGER, DIMENSION(:), POINTER           :: stacks_fillcount => Null()
      TYPE(dbcsr_mm_sched_type)                      :: sched = dbcsr_mm_sched_type()
      LOGICAL                                  :: keep_product_data = .FALSE.
   END TYPE dbcsr_mm_csr_type

#include "utils/dbcsr_hash_table_types.f90"

! **************************************************************************************************
   PUBLIC :: dbcsr_mm_csr_type
   PUBLIC :: dbcsr_mm_csr_lib_init, dbcsr_mm_csr_lib_finalize
   PUBLIC :: dbcsr_mm_csr_init, dbcsr_mm_csr_finalize
   PUBLIC :: dbcsr_mm_csr_multiply, dbcsr_mm_csr_purge_stacks
   PUBLIC :: dbcsr_mm_csr_dev2host_init, dbcsr_mm_csr_red3D

CONTAINS

   SUBROUTINE dbcsr_mm_csr_lib_init()
      !! Initialize the library

      CALL dbcsr_mm_sched_lib_init()
   END SUBROUTINE

   SUBROUTINE dbcsr_mm_csr_lib_finalize()
      !! Finalize the library
      CALL dbcsr_mm_sched_lib_finalize()
   END SUBROUTINE

   SUBROUTINE dbcsr_mm_csr_multiply(this, left, right, mi, mf, ni, nf, ki, kf, &
      !! A wrapper around dbcsr_mm_csr_multiply_low to avoid expensive dereferencings.
                                    ai, af, &
                                    bi, bf, &
                                    m_sizes, n_sizes, k_sizes, &
                                    c_local_rows, c_local_cols, &
                                    c_has_symmetry, keep_sparsity, use_eps, &
                                    row_max_epss, &
                                    flop, &
                                    a_index, b_index, a_norms, b_norms)
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right
      INTEGER, INTENT(IN)                                :: mi, mf, ni, nf, ki, kf, ai, af, bi, bf
      INTEGER, DIMENSION(:), INTENT(INOUT)               :: m_sizes, n_sizes, k_sizes, c_local_rows, &
                                                            c_local_cols
      LOGICAL, INTENT(INOUT)                             :: c_has_symmetry, keep_sparsity, use_eps
      REAL(kind=sp), DIMENSION(:)                        :: row_max_epss
      INTEGER(KIND=int_8), INTENT(INOUT)                 :: flop
      INTEGER, DIMENSION(1:3, 1:af), INTENT(IN)          :: a_index
      INTEGER, DIMENSION(1:3, 1:bf), INTENT(IN)          :: b_index
      REAL(KIND=sp), DIMENSION(:), POINTER               :: a_norms, b_norms

      INTEGER                                            :: ithread, max_new_nblks, nblks_new

      ithread = 0
!$    ithread = omp_get_thread_num()

      ! This has to be done here because ensure_array_size() expects a pointer.
      ! the maximum number of blocks can be safely estimated by considering both the rowxcol,
      ! but also the blocks the latter can never be larger than norec**2, which is a 'small' constant
      max_new_nblks = INT(MIN(INT(mf - mi + 1, int_8)*INT(nf - ni + 1, int_8), &
                              INT(af - ai + 1, int_8)*INT(bf - bi + 1, int_8)))

      nblks_new = this%product_wm%lastblk + max_new_nblks

      CALL ensure_array_size(this%product_wm%row_i, ub=nblks_new, &
                             factor=default_resize_factor)
      CALL ensure_array_size(this%product_wm%col_i, ub=nblks_new, &
                             factor=default_resize_factor)
      CALL ensure_array_size(this%product_wm%blk_p, ub=nblks_new, &
                             factor=default_resize_factor)

      CALL dbcsr_mm_csr_multiply_low(this, left=left, right=right, &
                                     mi=mi, mf=mf, ki=ki, kf=kf, &
                                     ai=ai, af=af, &
                                     bi=bi, bf=bf, &
                                     c_row_i=this%product_wm%row_i, &
                                     c_col_i=this%product_wm%col_i, &
                                     c_blk_p=this%product_wm%blk_p, &
                                     lastblk=this%product_wm%lastblk, &
                                     datasize=this%product_wm%datasize, &
                                     m_sizes=m_sizes, n_sizes=n_sizes, k_sizes=k_sizes, &
                                     c_local_rows=c_local_rows, c_local_cols=c_local_cols, &
                                     c_has_symmetry=c_has_symmetry, keep_sparsity=keep_sparsity, &
                                     use_eps=use_eps, &
                                     row_max_epss=row_max_epss, &
                                     flop=flop, &
                                     row_size_maps=this%m_size_maps, &
                                     col_size_maps=this%n_size_maps, &
                                     k_size_maps=this%k_size_maps, &
                                     row_size_maps_size=this%m_size_maps_size, &
                                     col_size_maps_size=this%n_size_maps_size, &
                                     k_size_maps_size=this%k_size_maps_size, &
                                     nm_stacks=this%nm_stacks, nn_stacks=this%nn_stacks, &
                                     nk_stacks=this%nk_stacks, &
                                     stack_map=this%stack_map, &
                                     stacks_data=this%stacks_data, &
                                     stacks_fillcount=this%stacks_fillcount, &
                                     c_hashes=this%c_hashes, &
                                     a_index=a_index, b_index=b_index, &
                                     a_norms=a_norms, b_norms=b_norms)

   END SUBROUTINE dbcsr_mm_csr_multiply

   SUBROUTINE dbcsr_mm_csr_multiply_low(this, left, right, mi, mf, ki, kf, &
      !! Performs multiplication of smaller submatrices.
                                        ai, af, bi, bf, &
                                        c_row_i, c_col_i, c_blk_p, lastblk, datasize, &
                                        m_sizes, n_sizes, k_sizes, &
                                        c_local_rows, c_local_cols, &
                                        c_has_symmetry, keep_sparsity, use_eps, &
                                        row_max_epss, flop, &
                                        row_size_maps, col_size_maps, k_size_maps, &
                                        row_size_maps_size, col_size_maps_size, k_size_maps_size, &
                                        nm_stacks, nn_stacks, nk_stacks, stack_map, &
                                        stacks_data, stacks_fillcount, c_hashes, &
                                        a_index, b_index, a_norms, b_norms)
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right
      INTEGER, INTENT(IN)                                :: mi, mf, ki, kf, ai, af, bi, bf
      INTEGER, DIMENSION(:), INTENT(INOUT)               :: c_row_i, c_col_i, c_blk_p
      INTEGER, INTENT(INOUT)                             :: lastblk, datasize
      INTEGER, DIMENSION(:), INTENT(IN)                  :: m_sizes, n_sizes, k_sizes, c_local_rows, &
                                                            c_local_cols
      LOGICAL, INTENT(IN)                                :: c_has_symmetry, keep_sparsity, use_eps
      REAL(kind=sp), DIMENSION(:)                        :: row_max_epss
      INTEGER(KIND=int_8), INTENT(INOUT)                 :: flop
      INTEGER, INTENT(IN)                                :: row_size_maps_size, k_size_maps_size, &
                                                            col_size_maps_size
      INTEGER(KIND=int_4), &
         DIMENSION(0:row_size_maps_size - 1), INTENT(IN)   :: row_size_maps
      INTEGER(KIND=int_4), &
         DIMENSION(0:col_size_maps_size - 1), INTENT(IN)   :: col_size_maps
      INTEGER(KIND=int_4), &
         DIMENSION(0:k_size_maps_size - 1), INTENT(IN)     :: k_size_maps
      INTEGER, INTENT(IN)                                :: nm_stacks, nn_stacks, nk_stacks
      INTEGER(KIND=int_1), DIMENSION(nn_stacks + 1, &
                                     nk_stacks + 1, nm_stacks + 1), INTENT(IN)           :: stack_map
      INTEGER, DIMENSION(:, :, :), INTENT(INOUT)         :: stacks_data
      INTEGER, DIMENSION(:), INTENT(INOUT)               :: stacks_fillcount
      TYPE(hash_table_type), DIMENSION(:), INTENT(INOUT) :: c_hashes
      INTEGER, DIMENSION(1:3, 1:af), INTENT(IN)          :: a_index
      INTEGER, DIMENSION(1:3, 1:bf), INTENT(IN)          :: b_index
      REAL(KIND=sp), DIMENSION(:), POINTER               :: a_norms, b_norms

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_csr_multiply_low'
      LOGICAL, PARAMETER                                 :: dbg = .FALSE.

      INTEGER :: a_blk, a_col_l, a_row_l, b_blk, b_col_l, c_blk_id, c_col_logical, c_nze, &
                 c_row_logical, ithread, k_size, m_size, mapped_col_size, mapped_k_size, mapped_row_size, &
                 n_a_norms, n_b_norms, n_size, nstacks, s_dp, ws
      INTEGER, DIMENSION(mi:mf + 1)                        :: a_row_p
      INTEGER, DIMENSION(ki:kf + 1)                        :: b_row_p
      INTEGER, DIMENSION(2, bf - bi + 1)                     :: b_blk_info
      INTEGER, DIMENSION(2, af - ai + 1)                     :: a_blk_info
      INTEGER(KIND=int_4)                                :: offset
      LOGICAL                                            :: block_exists
      REAL(kind=sp)                                      :: a_norm, a_row_eps, b_norm
      REAL(KIND=sp), DIMENSION(1:af - ai + 1)                :: left_norms
      REAL(KIND=sp), DIMENSION(1:bf - bi + 1)                :: right_norms

!   ---------------------------------------------------------------------------

      ithread = 0
!$    ithread = omp_get_thread_num()

      nstacks = SIZE(this%stacks_data, 3)

      IF (use_eps) THEN
         n_a_norms = af - ai + 1
         n_b_norms = bf - bi + 1
      ELSE
         n_a_norms = 0
         n_b_norms = 0
      END IF

      !
      ! Build the indices
      CALL build_csr_index(mi, mf, ai, af, a_row_p, a_blk_info, a_index, &
                           n_a_norms, left_norms, a_norms)
      CALL build_csr_index(ki, kf, bi, bf, b_row_p, b_blk_info, b_index, &
                           n_b_norms, right_norms, b_norms)

      a_row_cycle: DO a_row_l = mi, mf
         m_size = m_sizes(a_row_l)

         a_row_eps = row_max_epss(a_row_l)
         mapped_row_size = row_size_maps(m_size)

         a_blk_cycle: DO a_blk = a_row_p(a_row_l) + 1, a_row_p(a_row_l + 1)
            a_col_l = a_blk_info(1, a_blk)
            IF (debug_mod) WRITE (*, *) ithread, routineN//" A col", a_col_l, ";", a_row_l
            k_size = k_sizes(a_col_l)
            mapped_k_size = k_size_maps(k_size)

            a_norm = left_norms(a_blk)
            b_blk_cycle: DO b_blk = b_row_p(a_col_l) + 1, b_row_p(a_col_l + 1)
               IF (dbg) THEN
                  WRITE (*, '(1X,A,3(1X,I7),1X,A,1X,I16)') routineN//" trying B", &
                     a_row_l, b_blk_info(1, b_blk), a_col_l, "at", b_blk_info(2, b_blk)
               END IF
               b_norm = right_norms(b_blk)
               IF (a_norm*b_norm .LT. a_row_eps) THEN
                  CYCLE
               END IF
               b_col_l = b_blk_info(1, b_blk)
               ! Don't calculate symmetric blocks.
               symmetric_product: IF (c_has_symmetry) THEN
                  c_row_logical = c_local_rows(a_row_l)
                  c_col_logical = c_local_cols(b_col_l)
                  IF (c_row_logical .NE. c_col_logical &
                      .AND. my_checker_tr(c_row_logical, c_col_logical)) THEN
                     IF (dbg) THEN
                        WRITE (*, *) "Skipping symmetric block!", c_row_logical, &
                           c_col_logical
                     END IF
                     CYCLE
                  END IF
               END IF symmetric_product

               c_blk_id = hash_table_get(c_hashes(a_row_l), b_col_l)
               IF (.FALSE.) THEN
                  WRITE (*, '(1X,A,3(1X,I7),1X,A,1X,I16)') routineN//" coor", &
                     a_row_l, a_col_l, b_col_l, "c blk", c_blk_id
               END IF
               block_exists = c_blk_id .GT. 0

               n_size = n_sizes(b_col_l)
               c_nze = m_size*n_size
               !
               IF (block_exists) THEN
                  offset = c_blk_p(c_blk_id)
               ELSE
                  IF (keep_sparsity) CYCLE

                  offset = datasize + 1
                  lastblk = lastblk + 1
                  datasize = datasize + c_nze
                  c_blk_id = lastblk ! assign a new c-block-id

                  IF (dbg) WRITE (*, *) routineN//" new block offset, nze", offset, c_nze
                  CALL hash_table_add(c_hashes(a_row_l), &
                                      b_col_l, c_blk_id)

                  ! We still keep the linear index because it's
                  ! easier than getting the values out of the
                  ! hashtable in the end.
                  c_row_i(lastblk) = a_row_l
                  c_col_i(lastblk) = b_col_l
                  c_blk_p(lastblk) = offset
               END IF

               ! TODO: this is only called with careful_mod
               ! We should not call certain MM routines (netlib BLAS)
               ! with zero LDs; however, we still need to get to here
               ! to get new blocks.
               IF (careful_mod) THEN
                  IF (c_nze .EQ. 0 .OR. k_size .EQ. 0) THEN
                     DBCSR_ABORT("Can not call MM with LDx=0.")
                     CYCLE
                  END IF
               END IF

               mapped_col_size = col_size_maps(n_size)
               ws = stack_map(mapped_col_size, mapped_k_size, mapped_row_size)
               stacks_fillcount(ws) = stacks_fillcount(ws) + 1
               s_dp = stacks_fillcount(ws)

               stacks_data(p_m, s_dp, ws) = m_size
               stacks_data(p_n, s_dp, ws) = n_size
               stacks_data(p_k, s_dp, ws) = k_size
               stacks_data(p_a_first, s_dp, ws) = a_blk_info(2, a_blk)
               stacks_data(p_b_first, s_dp, ws) = b_blk_info(2, b_blk)
               stacks_data(p_c_first, s_dp, ws) = offset
               stacks_data(p_c_blk, s_dp, ws) = c_blk_id

               flop = flop + INT(2*c_nze, int_8)*INT(k_size, int_8)

               IF (stacks_fillcount(ws) >= SIZE(stacks_data, 2)) &
                  CALL flush_stacks(this, left=left, right=right)

            END DO b_blk_cycle ! b
         END DO a_blk_cycle ! a_col
      END DO a_row_cycle ! a_row

   END SUBROUTINE dbcsr_mm_csr_multiply_low

   SUBROUTINE dbcsr_mm_csr_init(this, left, right, product, &
      !! Initializes a multiplication cycle for new set of C-blocks.
                                m_sizes, n_sizes, block_estimate, right_row_blk_size, &
                                nlayers, keep_product_data)
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this
      TYPE(dbcsr_type), INTENT(IN), OPTIONAL             :: left, right
      TYPE(dbcsr_type), INTENT(INOUT)                    :: product
      INTEGER, DIMENSION(:), POINTER                     :: m_sizes, n_sizes
      INTEGER, INTENT(IN)                                :: block_estimate
      INTEGER, DIMENSION(:), INTENT(IN)                  :: right_row_blk_size
      INTEGER, OPTIONAL                                  :: nlayers
      LOGICAL, INTENT(IN)                                :: keep_product_data

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_mm_csr_init'

      INTEGER                                            :: default_stack, handle, istack, ithread, &
                                                            k_map, k_size, m_map, m_size, n_map, &
                                                            n_size, nstacks, nthreads, ps_g
      INTEGER, ALLOCATABLE, DIMENSION(:)                 :: flop_index, flop_list, most_common_k, &
                                                            most_common_m, most_common_n
      TYPE(stack_descriptor_type), ALLOCATABLE, &
         DIMENSION(:)                                    :: tmp_descr

      CALL timeset(routineN, handle)

      ithread = 0; nthreads = 1
!$    ithread = OMP_GET_THREAD_NUM(); nthreads = OMP_GET_NUM_THREADS()

      IF (PRESENT(left) .NEQV. PRESENT(right)) &
         DBCSR_ABORT("Must both left and right provided or not.")

      IF (PRESENT(left) .AND. PRESENT(right)) THEN
         ! find out if we have local_indexin
         IF (.NOT. right%local_indexing) &
            DBCSR_ABORT("Matrices must have local indexing.")
         IF (.NOT. left%local_indexing) &
            DBCSR_ABORT("Matrices must have local indexing.")
      END IF
      ! Setup the hash tables if needed
      ALLOCATE (this%c_hashes(product%nblkrows_local))
      CALL fill_hash_tables(this%c_hashes, product, block_estimate, &
                            row_map=array_data(product%global_rows), &
                            col_map=array_data(product%global_cols))

      ! Setup the MM stack
      this%nm_stacks = dbcsr_cfg%n_stacks%val
      this%nn_stacks = dbcsr_cfg%n_stacks%val
      this%nk_stacks = dbcsr_cfg%n_stacks%val
      nstacks = this%nm_stacks*this%nn_stacks*this%nk_stacks + 1
      IF (nstacks > INT(HUGE(this%stack_map))) &
         DBCSR_ABORT("Too many stacks requested (global/dbcsr/n_size_*_stacks in input)")

      ALLOCATE (this%stacks_descr(nstacks))
      ALLOCATE (this%stacks_data(dbcsr_ps_width, dbcsr_cfg%mm_stack_size%val, nstacks))
      ALLOCATE (this%stacks_fillcount(nstacks))
      this%stacks_fillcount(:) = 0

      ALLOCATE (most_common_m(this%nm_stacks))
      ALLOCATE (most_common_n(this%nn_stacks))
      ALLOCATE (most_common_k(this%nk_stacks))
      CALL map_most_common(m_sizes, this%m_size_maps, this%nm_stacks, &
                           most_common_m, &
                           max_stack_block_size, this%max_m)
      this%m_size_maps_size = SIZE(this%m_size_maps)
      CALL map_most_common(n_sizes, this%n_size_maps, this%nn_stacks, &
                           most_common_n, &
                           max_stack_block_size, this%max_n)
      this%n_size_maps_size = SIZE(this%n_size_maps)
      CALL map_most_common(right_row_blk_size, &
                           this%k_size_maps, this%nk_stacks, &
                           most_common_k, &
                           max_stack_block_size, this%max_k)
      this%k_size_maps_size = SIZE(this%k_size_maps)

      ! Creates the stack map--a mapping from (mapped) stack block sizes
      ! (carrier%*_sizes) to a stack number.  Triples with even one
      ! uncommon size will be mapped to a general, non-size-specific
      ! stack.
      ALLOCATE (this%stack_map(this%nn_stacks + 1, this%nk_stacks + 1, this%nm_stacks + 1))
      default_stack = nstacks

      DO m_map = 1, this%nm_stacks + 1
         IF (m_map .LE. this%nm_stacks) THEN
            m_size = most_common_m(m_map)
         ELSE
            m_size = 777
         END IF
         DO k_map = 1, this%nk_stacks + 1
            IF (k_map .LE. this%nk_stacks) THEN
               k_size = most_common_k(k_map)
            ELSE
               k_size = 888
            END IF
            DO n_map = 1, this%nn_stacks + 1
               IF (n_map .LE. this%nn_stacks) THEN
                  n_size = most_common_n(n_map)
               ELSE
                  n_size = 999
               END IF
               IF (m_map .LE. this%nm_stacks &
                   .AND. k_map .LE. this%nk_stacks &
                   .AND. n_map .LE. this%nn_stacks) THEN
                  ! This is the case when m, n, and k are all defined.
                  ps_g = (m_map - 1)*this%nn_stacks*this%nk_stacks + &
                         (k_map - 1)*this%nn_stacks + n_map
                  ps_g = nstacks - ps_g
                  this%stack_map(n_map, k_map, m_map) = INT(ps_g, kind=int_1)
                  ! Also take care of the stack m, n, k descriptors
                  this%stacks_descr(ps_g)%m = m_size
                  this%stacks_descr(ps_g)%n = n_size
                  this%stacks_descr(ps_g)%k = k_size
                  this%stacks_descr(ps_g)%max_m = m_size
                  this%stacks_descr(ps_g)%max_n = n_size
                  this%stacks_descr(ps_g)%max_k = k_size
                  this%stacks_descr(ps_g)%defined_mnk = .TRUE.
               ELSE
                  ! This is the case when at least one of m, n, or k is
                  ! undefined.
                  ps_g = default_stack
                  this%stack_map(n_map, k_map, m_map) = INT(default_stack, kind=int_1)
                  ! Also take care of the stack m, n, k descriptors
                  this%stacks_descr(ps_g)%m = 0
                  this%stacks_descr(ps_g)%n = 0
                  this%stacks_descr(ps_g)%k = 0
                  this%stacks_descr(ps_g)%max_m = this%max_m
                  this%stacks_descr(ps_g)%max_n = this%max_n
                  this%stacks_descr(ps_g)%max_k = this%max_k
                  this%stacks_descr(ps_g)%defined_mnk = .FALSE.
               END IF
            END DO
         END DO
      END DO
      DEALLOCATE (most_common_m)
      DEALLOCATE (most_common_n)
      DEALLOCATE (most_common_k)

      ! sort to make the order fixed... all defined stacks first, default stack
      ! last. Next, sort according to flops, first stack lots of flops, last
      ! stack, few flops
      ! The default stack shall remain at the end of the gridcolumn
      ALLOCATE (flop_list(nstacks - 1), flop_index(nstacks - 1), tmp_descr(nstacks))
      DO istack = 1, nstacks - 1
         flop_list(istack) = -2*this%stacks_descr(istack)%m &
                             *this%stacks_descr(istack)%n &
                             *this%stacks_descr(istack)%k
      END DO

      CALL sort(flop_list, nstacks - 1, flop_index)
      tmp_descr(:) = this%stacks_descr
      DO istack = 1, nstacks - 1
         this%stacks_descr(istack) = tmp_descr(flop_index(istack))
      END DO

      DO m_map = 1, SIZE(this%stack_map, 1)
         DO k_map = 1, SIZE(this%stack_map, 2)
            map_loop: DO n_map = 1, SIZE(this%stack_map, 1)
               DO istack = 1, nstacks - 1
                  IF (this%stack_map(m_map, k_map, n_map) == flop_index(istack)) THEN
                     this%stack_map(m_map, k_map, n_map) = INT(istack, kind=int_1)
                     CYCLE map_loop
                  END IF
               END DO
            END DO map_loop
         END DO
      END DO
      DEALLOCATE (flop_list, flop_index, tmp_descr)

      this%keep_product_data = keep_product_data

      this%product_wm => product%wms(ithread + 1)
      CALL dbcsr_mm_sched_init(this%sched, &
                               product_wm=this%product_wm, &
                               nlayers=nlayers, &
                               keep_product_data=keep_product_data)

      CALL timestop(handle)

   END SUBROUTINE dbcsr_mm_csr_init

   SUBROUTINE fill_hash_tables(hashes, matrix, block_estimate, row_map, col_map)
      !! Fills row hashtable from an existing matrix.

      TYPE(hash_table_type), DIMENSION(:), INTENT(inout) :: hashes
      TYPE(dbcsr_type), INTENT(IN)                       :: matrix
      INTEGER                                            :: block_estimate
         !! guess for the number of blocks in the product matrix, can be zero
      INTEGER, DIMENSION(:), INTENT(IN)                  :: row_map, col_map

      CHARACTER(len=*), PARAMETER :: routineN = 'fill_hash_tables'

      INTEGER                                            :: col, handle, i, imat, n_rows, row

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, handle)
      imat = 1
!$    imat = OMP_GET_THREAD_NUM() + 1
      n_rows = matrix%nblkrows_local
      IF (SIZE(hashes) /= n_rows) &
         DBCSR_ABORT("Local row count mismatch")
      DO row = 1, n_rows
         ! create the hash table row with a reasonable initial size
         CALL hash_table_create(hashes(row), &
                                MAX(8, (3*block_estimate)/MAX(1, n_rows)))
      END DO
      ! We avoid using the iterator because we will use the existing
      ! work matrix instead of the BCSR index.
      DO i = 1, matrix%wms(imat)%lastblk
         row = matrix%wms(imat)%row_i(i)
         col = matrix%wms(imat)%col_i(i)
         row = row_map(row)
         col = col_map(col)
         CALL hash_table_add(hashes(row), col, i)
      END DO
      CALL timestop(handle)
   END SUBROUTINE fill_hash_tables

   SUBROUTINE dbcsr_mm_csr_finalize(this)
      !! Finalizes a multiplication cycle for a set of C-blocks.
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this

      INTEGER                                            :: i

      CALL dbcsr_mm_sched_finalize(this%sched)

      ! Clear hash tables
      DO i = 1, SIZE(this%c_hashes)
         CALL hash_table_release(this%c_hashes(i))
      END DO
      DEALLOCATE (this%c_hashes)
      DEALLOCATE (this%stacks_descr)
      DEALLOCATE (this%stack_map)
      DEALLOCATE (this%m_size_maps)
      DEALLOCATE (this%n_size_maps)
      DEALLOCATE (this%k_size_maps)
      DEALLOCATE (this%stacks_fillcount)
      DEALLOCATE (this%stacks_data)
   END SUBROUTINE dbcsr_mm_csr_finalize

   SUBROUTINE dbcsr_mm_csr_dev2host_init(this)
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this

      CALL dbcsr_mm_sched_dev2host_init(this%sched)

   END SUBROUTINE dbcsr_mm_csr_dev2host_init

   SUBROUTINE dbcsr_mm_csr_red3D(this, meta_buffer, data_buffer, flop, m_sizes, n_sizes, &
      !! Make the reduction of the 3D layers in the local csr object
                                 g2l_map_rows, g2l_map_cols, original_lastblk, &
                                 keep_sparsity)
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this
      INTEGER, DIMENSION(:), INTENT(IN), TARGET          :: meta_buffer
      TYPE(dbcsr_data_obj), INTENT(IN)                   :: data_buffer
      INTEGER(KIND=int_8), INTENT(INOUT)                 :: flop
      INTEGER, DIMENSION(:), INTENT(IN)                  :: m_sizes, n_sizes, g2l_map_rows, &
                                                            g2l_map_cols
      INTEGER, INTENT(IN)                                :: original_lastblk
      LOGICAL, INTENT(IN)                                :: keep_sparsity

      INTEGER                                            :: c_blk_id, iblock, ithread, lb, lb_data, &
                                                            lb_meta, nblks_max, nblocks, nthreads, &
                                                            nze, nze_max, ub_meta
      INTEGER, DIMENSION(:), POINTER                     :: blk_p, col_i, row_i
      LOGICAL                                            :: block_exists

      ithread = 0; nthreads = 1
!$    ithread = OMP_GET_THREAD_NUM(); nthreads = OMP_GET_NUM_THREADS()
      lb_meta = meta_buffer(ithread + 1)
      nblocks = (meta_buffer(ithread + 2) - lb_meta)/3
      ub_meta = lb_meta + nblocks
      row_i => meta_buffer(lb_meta + 1:ub_meta)
      lb_meta = ub_meta
      ub_meta = lb_meta + nblocks
      col_i => meta_buffer(lb_meta + 1:ub_meta)
      ! Make local indexing if needed
      IF (keep_sparsity) THEN
         DO iblock = 1, original_lastblk
            row_i(iblock) = g2l_map_rows(row_i(iblock))
            col_i(iblock) = g2l_map_cols(col_i(iblock))
         END DO
      END IF
      lb_meta = ub_meta
      ub_meta = lb_meta + nblocks
      blk_p => meta_buffer(lb_meta + 1:ub_meta)
      !
      ! Get sizes
      nze_max = this%product_wm%datasize
      nblks_max = this%product_wm%lastblk
      DO iblock = 1, nblocks
         nze = m_sizes(row_i(iblock))*n_sizes(col_i(iblock))
         IF (nze .EQ. 0) CYCLE
         c_blk_id = hash_table_get(this%c_hashes(row_i(iblock)), col_i(iblock))
         block_exists = c_blk_id .GT. 0
         IF (block_exists) CYCLE
         nblks_max = nblks_max + 1
         nze_max = nze_max + nze
      END DO
      ! Resize buffers
      CALL dbcsr_data_ensure_size(this%product_wm%data_area, &
                                  nze_max, factor=default_resize_factor, nocopy=.FALSE., &
                                  zero_pad=.TRUE.)
      CALL ensure_array_size(this%product_wm%row_i, ub=nblks_max, &
                             factor=default_resize_factor, nocopy=.FALSE.)
      CALL ensure_array_size(this%product_wm%col_i, ub=nblks_max, &
                             factor=default_resize_factor, nocopy=.FALSE.)
      CALL ensure_array_size(this%product_wm%blk_p, ub=nblks_max, &
                             factor=default_resize_factor, nocopy=.FALSE.)
      DO iblock = 1, nblocks
         nze = m_sizes(row_i(iblock))*n_sizes(col_i(iblock))
         IF (nze .EQ. 0) CYCLE
         lb_data = blk_p(iblock)
         c_blk_id = hash_table_get(this%c_hashes(row_i(iblock)), col_i(iblock))
         block_exists = c_blk_id .GT. 0
         IF (block_exists) THEN
            lb = this%product_wm%blk_p(c_blk_id)
            CALL block_add(this%product_wm%data_area, data_buffer, &
                           lb, lb_data, nze)
            flop = flop + nze
         ELSE
            lb = this%product_wm%datasize + 1
            this%product_wm%lastblk = this%product_wm%lastblk + 1
            this%product_wm%datasize = this%product_wm%datasize + nze
            c_blk_id = this%product_wm%lastblk ! assign a new c-block-id
            CALL hash_table_add(this%c_hashes(row_i(iblock)), col_i(iblock), c_blk_id)
            this%product_wm%row_i(this%product_wm%lastblk) = row_i(iblock)
            this%product_wm%col_i(this%product_wm%lastblk) = col_i(iblock)
            this%product_wm%blk_p(this%product_wm%lastblk) = lb
            !
            CALL dbcsr_block_copy_aa(this%product_wm%data_area, data_buffer, &
                                     m_sizes(row_i(iblock)), n_sizes(col_i(iblock)), lb, lb_data)
         END IF
      END DO
      CALL dbcsr_mm_sched_set_orig_datasize(this%sched, this%product_wm%datasize)
   END SUBROUTINE dbcsr_mm_csr_red3D

   SUBROUTINE dbcsr_mm_csr_purge_stacks(this, left, right)
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right

      CALL flush_stacks(this, left, right, purge=.TRUE.)
      CALL dbcsr_mm_sched_barrier()
   END SUBROUTINE dbcsr_mm_csr_purge_stacks

   SUBROUTINE flush_stacks(this, left, right, purge)
      TYPE(dbcsr_mm_csr_type), INTENT(INOUT)             :: this
      TYPE(dbcsr_type), INTENT(IN)                       :: left, right
      LOGICAL, INTENT(IN), OPTIONAL                      :: purge

      INTEGER                                            :: i, min_fill, n_stacks
      INTEGER, DIMENSION(:, :), POINTER                  :: stack_data
      INTEGER, POINTER                                   :: stack_fillcount
      TYPE(stack_descriptor_type)                        :: stack_descr

      n_stacks = SIZE(this%stacks_data, 3)
      min_fill = SIZE(this%stacks_data, 2)*3/4 !TODO: play with this
      IF (PRESENT(purge)) THEN
         IF (purge) min_fill = 0
      END IF

      CALL dbcsr_mm_sched_begin_burst(this%sched)

      DO i = 1, n_stacks
         IF (this%stacks_fillcount(i) > min_fill) THEN
            stack_data => this%stacks_data(:, :, i)
            stack_fillcount => this%stacks_fillcount(i)
            stack_descr = this%stacks_descr(i)

            CALL dbcsr_mm_sched_process(this%sched, &
                                        left, right, &
                                        stack_data=stack_data, &
                                        stack_fillcount=stack_fillcount, &
                                        stack_descr=stack_descr)

            stack_fillcount = 0
         END IF
      END DO

      CALL dbcsr_mm_sched_end_burst()
   END SUBROUTINE flush_stacks

   SUBROUTINE build_csr_index(mi, mf, ai, af, row_p, blk_info, list_index, &
      !! Builds and sorts a CSR index from a list index.
                              nnorms, csr_norms, list_norms)
      INTEGER, INTENT(IN)                                :: mi, mf, ai, af
      INTEGER, DIMENSION(mi:mf + 1), INTENT(OUT)           :: row_p
      INTEGER, DIMENSION(2, 1:af - ai + 1), INTENT(OUT)      :: blk_info
      INTEGER, DIMENSION(3, 1:af), INTENT(IN)            :: list_index
      INTEGER, INTENT(IN)                                :: nnorms
      REAL(KIND=sp), DIMENSION(1:af - ai + 1), INTENT(OUT)   :: csr_norms
      REAL(KIND=sp), DIMENSION(:), INTENT(IN)            :: list_norms

      LOGICAL, PARAMETER                                 :: careful = .FALSE., dbg = .FALSE.

      INTEGER                                            :: i, row
      INTEGER, DIMENSION(mi:mf)                          :: counts

!   ---------------------------------------------------------------------------
! Counts blocks per row and calculates the offsets.

      IF (dbg) THEN
         WRITE (*, '(I7,1X,5(A,2(1X,I7)))') 0, "bci", mi, mf, ";", ai, af
         !write(*,'(3(I7))')list_index(:,ai:af)
      END IF

      counts(:) = 0
      DO i = ai, af
         IF (careful) THEN
            IF (list_index(1, i) < mi) DBCSR_ABORT("Out of range")
            IF (list_index(1, i) > mf) DBCSR_ABORT("Out of range")
         END IF
         counts(list_index(1, i)) = counts(list_index(1, i)) + 1
      END DO
      row_p(mi) = 0
      DO i = mi + 1, mf + 1
         row_p(i) = row_p(i - 1) + counts(i - 1)
      END DO
      ! Adds every block to its corresponding row.
      counts(:) = 0
      DO i = ai, af
         row = list_index(1, i)
         counts(row) = counts(row) + 1
         IF (careful) THEN
            IF (row_p(row) + counts(row) > af - ai + 1) DBCSR_ABORT("Out of range")
            IF (row_p(row) + counts(row) < 1) DBCSR_ABORT("Out of range")
         END IF
         blk_info(1, row_p(row) + counts(row)) = list_index(2, i)
         blk_info(2, row_p(row) + counts(row)) = list_index(3, i)
         IF (nnorms .GT. 0) THEN
            csr_norms(row_p(row) + counts(row)) = list_norms(i)
         END IF
      END DO
      IF (nnorms .EQ. 0) THEN
         csr_norms(:) = 0.0_sp
      END IF
   END SUBROUTINE build_csr_index

   ELEMENTAL FUNCTION my_checker_tr(row, column) RESULT(transpose)
      !! Determines whether a transpose must be applied
      !!
      !! Source
      !! This function is copied from dbcsr_dist_operations for speed reasons.

      INTEGER, INTENT(IN)                                :: row, column
         !! The absolute matrix row.
         !! The absolute matrix column.
      LOGICAL                                            :: transpose

      transpose = BTEST(column + row, 0) .EQV. column .GE. row

   END FUNCTION my_checker_tr

#include "utils/dbcsr_hash_table.f90"

END MODULE dbcsr_mm_csr
