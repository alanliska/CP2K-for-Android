!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_tests
   !! Tests for CP2K DBCSR operations
   USE dbcsr_data_methods, ONLY: dbcsr_scalar
   USE dbcsr_dist_methods, ONLY: dbcsr_distribution_mp, &
                                 dbcsr_distribution_new, &
                                 dbcsr_distribution_release
   USE dbcsr_dist_operations, ONLY: dbcsr_dist_bin
   USE dbcsr_dist_util, ONLY: dbcsr_checksum
   USE dbcsr_io, ONLY: dbcsr_binary_read, &
                       dbcsr_binary_write
   USE dbcsr_kinds, ONLY: dp, &
                          int_8, &
                          real_8
   USE dbcsr_machine, ONLY: m_flush, &
                            m_walltime
   USE dbcsr_methods, ONLY: dbcsr_col_block_sizes, &
                            dbcsr_distribution, &
                            dbcsr_get_data_type, &
                            dbcsr_name, &
                            dbcsr_nblkcols_total, &
                            dbcsr_nblkrows_total, &
                            dbcsr_release, &
                            dbcsr_row_block_sizes
   USE dbcsr_mp_methods, ONLY: dbcsr_mp_active, &
                               dbcsr_mp_group, &
                               dbcsr_mp_init, &
                               dbcsr_mp_new, &
                               dbcsr_mp_npcols, &
                               dbcsr_mp_nprows, &
                               dbcsr_mp_release, &
                               dbcsr_mp_make_env
   USE dbcsr_mpiwrap, ONLY: &
      mp_comm_free, mp_environ, mp_max, mp_sum, mp_sync, mp_comm_type
   USE dbcsr_multiply_api, ONLY: dbcsr_multiply
   USE dbcsr_operations, ONLY: dbcsr_add, &
                               dbcsr_copy, &
                               dbcsr_frobenius_norm
   USE dbcsr_test_methods, ONLY: dbcsr_make_random_block_sizes, &
                                 dbcsr_make_random_matrix
   USE dbcsr_transformations, ONLY: dbcsr_redistribute
   USE dbcsr_types, ONLY: dbcsr_distribution_obj, &
                          dbcsr_mp_obj, &
                          dbcsr_scalar_type, &
                          dbcsr_type, &
                          dbcsr_type_no_symmetry
   USE dbcsr_work_operations, ONLY: dbcsr_create
#include "base/dbcsr_base_uses.f90"

!$ USE OMP_LIB, ONLY: omp_get_max_threads, omp_get_thread_num, omp_get_num_threads

   IMPLICIT NONE

   PRIVATE

   PUBLIC :: dbcsr_run_tests, dbcsr_test_mm, dbcsr_test_binary_io

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_tests'

   INTEGER, PARAMETER          :: dbcsr_test_mm = 1
   INTEGER, PARAMETER          :: dbcsr_test_binary_io = 2

CONTAINS

   SUBROUTINE dbcsr_run_tests(mp_group, io_unit, nproc, &
                              matrix_sizes, trs, &
                              bs_m, bs_n, bs_k, sparsities, alpha, beta, data_type, test_type, &
                              n_loops, eps, retain_sparsity, always_checksum)
      !! Performs a variety of matrix multiplies of same matrices on different
      !! processor grids

      TYPE(mp_comm_type), INTENT(IN)                     :: mp_group
      INTEGER, INTENT(IN)                                :: io_unit
         !! MPI communicator
         !! which unit to write to, if not negative
      INTEGER, DIMENSION(:), POINTER                     :: nproc
         !! number of processors to test on
      INTEGER, DIMENSION(:), INTENT(in)                  :: matrix_sizes
         !! size of matrices to test
      LOGICAL, DIMENSION(2), INTENT(in)                  :: trs
         !! transposes of the two matrices
      INTEGER, DIMENSION(:), POINTER                     :: bs_m, bs_n, bs_k
         !! block sizes of the 3 dimensions
         !! block sizes of the 3 dimensions
         !! block sizes of the 3 dimensions
      REAL(kind=dp), DIMENSION(3), INTENT(in)            :: sparsities
         !! sparsities of matrices to create
      REAL(kind=dp), INTENT(in)                          :: alpha, beta
         !! alpha value to use in multiply
         !! beta value to use in multiply
      INTEGER, INTENT(IN)                                :: data_type, test_type, n_loops
         !! matrix data type
         !! number of repetition for each multiplication
      REAL(kind=dp), INTENT(in)                          :: eps
         !! eps value for filtering
      LOGICAL, INTENT(in)                                :: retain_sparsity, always_checksum
         !! checksum after each multiplication

      CHARACTER(len=*), PARAMETER :: fmt_desc = '(A,3(1X,I6),1X,A,2(1X,I5),1X,A,2(1X,L1))', &
                                     routineN = 'dbcsr_run_tests'

      CHARACTER                                          :: t_a, t_b
      INTEGER                                            :: bmax, bmin, error_handle, &
                                                            mynode, numnodes
      INTEGER, ALLOCATABLE, DIMENSION(:, :)              :: group_sizes
      INTEGER, DIMENSION(2)                              :: npdims
      INTEGER, DIMENSION(:), POINTER, CONTIGUOUS         :: col_dist_a, col_dist_b, col_dist_c, &
                                                            row_dist_a, row_dist_b, row_dist_c, &
                                                            sizes_k, sizes_m, sizes_n
      LOGICAL                                            :: pgiven
      TYPE(dbcsr_distribution_obj)                       :: dist_a, dist_b, dist_c
      TYPE(dbcsr_mp_obj)                                 :: mp_env
      TYPE(dbcsr_type), TARGET                           :: matrix_a, matrix_b, matrix_c
      TYPE(mp_comm_type)                                 :: cart_group

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, error_handle)
      ! Create the row/column block sizes.
      IF (ASSOCIATED(bs_m)) THEN
         bmin = MINVAL(bs_m(2::2))
         bmax = MAXVAL(bs_m(2::2))
         CALL dbcsr_make_random_block_sizes(sizes_m, matrix_sizes(1), bs_m)
      ELSE
         CALL dbcsr_make_random_block_sizes(sizes_m, matrix_sizes(1), (/1, 13, 2, 5/))
         bmin = 5; bmax = 13
      END IF
      IF (ASSOCIATED(bs_n)) THEN
         bmin = MIN(bmin, MINVAL(bs_n(2::2)))
         bmax = MAX(bmax, MAXVAL(bs_n(2::2)))
         CALL dbcsr_make_random_block_sizes(sizes_n, matrix_sizes(2), bs_n)
      ELSE
         CALL dbcsr_make_random_block_sizes(sizes_n, matrix_sizes(2), (/1, 13, 2, 5/))
         bmin = MIN(bmin, 5); bmax = MAX(bmax, 13)
      END IF
      IF (ASSOCIATED(bs_k)) THEN
         bmin = MIN(bmin, MINVAL(bs_k(2::2)))
         bmax = MAX(bmax, MAXVAL(bs_k(2::2)))
         CALL dbcsr_make_random_block_sizes(sizes_k, matrix_sizes(3), bs_k)
      ELSE
         CALL dbcsr_make_random_block_sizes(sizes_k, matrix_sizes(3), (/1, 13, 2, 5/))
         bmin = MIN(bmin, 5); bmax = MAX(bmax, 13)
      END IF
      !
      ! Create dist

      ! Create the random matrices.
      CALL dbcsr_mp_make_env(mp_env, cart_group, mp_group)
      npdims(1) = dbcsr_mp_nprows(mp_env)
      npdims(2) = dbcsr_mp_npcols(mp_env)
      CALL dbcsr_dist_bin(row_dist_c, SIZE(sizes_m), npdims(1), &
                          sizes_m)
      CALL dbcsr_dist_bin(col_dist_c, SIZE(sizes_n), npdims(2), &
                          sizes_n)
      CALL dbcsr_distribution_new(dist_c, mp_env, row_dist_c, col_dist_c)
      CALL dbcsr_make_random_matrix(matrix_c, sizes_m, sizes_n, "Matrix C", &
                                    REAL(sparsities(3), real_8), &
                                    mp_group, data_type=data_type, dist=dist_c)
      CALL dbcsr_distribution_release(dist_c)
      IF (trs(1)) THEN
         CALL dbcsr_dist_bin(row_dist_a, SIZE(sizes_k), npdims(1), &
                             sizes_k)
         CALL dbcsr_dist_bin(col_dist_a, SIZE(sizes_m), npdims(2), &
                             sizes_m)
         CALL dbcsr_distribution_new(dist_a, mp_env, row_dist_a, col_dist_a)
         CALL dbcsr_make_random_matrix(matrix_a, sizes_k, sizes_m, "Matrix A", &
                                       REAL(sparsities(1), real_8), &
                                       mp_group, data_type=data_type, dist=dist_a)
         DEALLOCATE (row_dist_a, col_dist_a)
      ELSE
         CALL dbcsr_dist_bin(col_dist_a, SIZE(sizes_k), npdims(2), &
                             sizes_k)
         CALL dbcsr_distribution_new(dist_a, mp_env, row_dist_c, col_dist_a)
         CALL dbcsr_make_random_matrix(matrix_a, sizes_m, sizes_k, "Matrix A", &
                                       REAL(sparsities(1), real_8), &
                                       mp_group, data_type=data_type, dist=dist_a)
         DEALLOCATE (col_dist_a)
      END IF
      CALL dbcsr_distribution_release(dist_a)
      IF (trs(2)) THEN
         CALL dbcsr_dist_bin(row_dist_b, SIZE(sizes_n), npdims(1), &
                             sizes_n)
         CALL dbcsr_dist_bin(col_dist_b, SIZE(sizes_k), npdims(2), &
                             sizes_k)
         CALL dbcsr_distribution_new(dist_b, mp_env, row_dist_b, col_dist_b)
         CALL dbcsr_make_random_matrix(matrix_b, sizes_n, sizes_k, "Matrix B", &
                                       REAL(sparsities(2), real_8), &
                                       mp_group, data_type=data_type, dist=dist_b)
         DEALLOCATE (row_dist_b, col_dist_b)
      ELSE
         CALL dbcsr_dist_bin(row_dist_b, SIZE(sizes_k), npdims(1), &
                             sizes_k)
         CALL dbcsr_distribution_new(dist_b, mp_env, row_dist_b, col_dist_c)
         CALL dbcsr_make_random_matrix(matrix_b, sizes_k, sizes_n, "Matrix B", &
                                       REAL(sparsities(2), real_8), &
                                       mp_group, data_type=data_type, dist=dist_b)
         DEALLOCATE (row_dist_b)
      END IF
      CALL dbcsr_mp_release(mp_env)
      CALL dbcsr_distribution_release(dist_b)
      DEALLOCATE (row_dist_c, col_dist_c)
      DEALLOCATE (sizes_m, sizes_n, sizes_k)
      ! Prepare test parameters
      IF (io_unit .GT. 0) THEN
         WRITE (io_unit, fmt_desc) "Testing with sizes", matrix_sizes(1:3), &
            "min/max block sizes", bmin, bmax, "transposed?", trs(1:2)
      END IF
      CALL mp_environ(numnodes, mynode, mp_group)
      pgiven = ASSOCIATED(nproc)
      IF (pgiven) pgiven = nproc(1) .NE. 0
      IF (pgiven) THEN
         ALLOCATE (group_sizes(SIZE(nproc), 2))
         group_sizes(:, 1) = nproc(:)
         group_sizes(:, 2) = 0
      ELSE
         !ALLOCATE (group_sizes (numnodes, 2))
         !DO test = numnodes, 1, -1
         !   group_sizes(1+numnodes-test, 1:2) = (/ test, 0 /)
         !ENDDO
         ALLOCATE (group_sizes(1, 2))
         group_sizes(1, 1:2) = (/numnodes, 0/)
      END IF
      t_a = 'N'; IF (trs(1)) t_a = 'T'
      t_b = 'N'; IF (trs(2)) t_b = 'T'

      SELECT CASE (test_type)
      CASE (dbcsr_test_mm)
         CALL test_multiplies_multiproc(group_sizes, &
                                        matrix_a, matrix_b, matrix_c, t_a, t_b, &
                                        dbcsr_scalar(REAL(alpha, real_8)), dbcsr_scalar(REAL(beta, real_8)), &
                                        n_loops=n_loops, eps=eps, &
                                        io_unit=io_unit, always_checksum=always_checksum, &
                                        retain_sparsity=retain_sparsity)
      CASE (dbcsr_test_binary_io)
         CALL test_binary_io(matrix_a, io_unit)
      END SELECT

      CALL dbcsr_release(matrix_a)
      CALL dbcsr_release(matrix_b)
      CALL dbcsr_release(matrix_c)
      CALL mp_comm_free(cart_group)
      CALL timestop(error_handle)
   END SUBROUTINE dbcsr_run_tests

   SUBROUTINE test_binary_io(matrix_a, io_unit)
      !! dumps and retrieves a dbcsr matrix, and checks a checksum

      TYPE(dbcsr_type)                                   :: matrix_a
         !! matrix to be written
      INTEGER                                            :: io_unit
         !! unit for status updates

      CHARACTER(LEN=100)                                 :: file_name
      REAL(kind=real_8)                                  :: norm, post, pre
      TYPE(dbcsr_type)                                   :: matrix_a_read

      file_name = "test_dbcsr_binary_io.dat"

      pre = dbcsr_checksum(matrix_a, pos=.TRUE.)

      CALL dbcsr_binary_write(matrix_a, file_name)

      ! needs a new matrix, reading into matrix_a does not work
      CALL dbcsr_binary_read(file_name, distribution=dbcsr_distribution(matrix_a), &
                             matrix_new=matrix_a_read)

      post = dbcsr_checksum(matrix_a_read, pos=.TRUE.)
      CALL dbcsr_add(matrix_a_read, matrix_a, -1.0_dp, 1.0_dp)
      norm = dbcsr_frobenius_norm(matrix_a_read)
      IF (io_unit > 0) THEN
         WRITE (io_unit, *) "checksums", pre, post
         WRITE (io_unit, *) "difference norm", norm
      END IF

      IF (norm /= 0.0_dp) &
         DBCSR_ABORT("bug in binary io")

      CALL dbcsr_release(matrix_a_read)

   END SUBROUTINE test_binary_io

   SUBROUTINE test_multiplies_multiproc(group_sizes, &
                                        matrix_a, matrix_b, matrix_c, &
                                        transa, transb, alpha, beta, limits, retain_sparsity, &
                                        n_loops, eps, &
                                        io_unit, always_checksum)
      !! Performs a variety of matrix multiplies of same matrices on different
      !! processor grids

      INTEGER, DIMENSION(:, :)                           :: group_sizes
         !! array of (sub) communicator sizes to test (2-D)
      TYPE(dbcsr_type), INTENT(in)                       :: matrix_a, matrix_b, matrix_c
         !! matrices to multiply
         !! matrices to multiply
         !! matrices to multiply
      CHARACTER, INTENT(in)                              :: transa, transb
      TYPE(dbcsr_scalar_type), INTENT(in)                :: alpha, beta
      INTEGER, DIMENSION(6), INTENT(in), OPTIONAL        :: limits
      LOGICAL, INTENT(in), OPTIONAL                      :: retain_sparsity
      INTEGER, INTENT(IN)                                :: n_loops
      REAL(kind=dp), INTENT(in)                          :: eps
      INTEGER, INTENT(IN)                                :: io_unit
         !! which unit to write to, if not negative
      LOGICAL                                            :: always_checksum

      CHARACTER(len=*), PARAMETER :: routineN = 'test_multiplies_multiproc'

      INTEGER                                            :: error_handle, &
                                                            loop_iter, mynode, numnodes, test
      INTEGER(kind=int_8)                                :: flop, flop_sum
      INTEGER, DIMENSION(2)                              :: npdims
      INTEGER, DIMENSION(:), POINTER, CONTIGUOUS         :: col_dist_a, col_dist_b, col_dist_c, &
                                                            row_dist_a, row_dist_b, row_dist_c
      LOGICAL                                            :: i_am_alive
      REAL(kind=real_8)                                  :: cs, cs_pos, flops_all, t1, t2
      TYPE(dbcsr_distribution_obj)                       :: dist_a, dist_b, dist_c
      TYPE(dbcsr_mp_obj)                                 :: mp_env
      TYPE(dbcsr_type)                                   :: m_a, m_b, m_c, m_c_reserve
      TYPE(mp_comm_type)                                 :: cart_group, group

!   ---------------------------------------------------------------------------

      CALL timeset(routineN, error_handle)
      IF (SIZE(group_sizes, 2) /= 2) &
         DBCSR_ABORT("second dimension of group_sizes must be 2")
      p_sizes: DO test = 1, SIZE(group_sizes, 1)
         t2 = 0.0_real_8
         flop_sum = 0
         npdims(1:2) = group_sizes(test, 1:2)
         numnodes = npdims(1)*npdims(2)
         group = dbcsr_mp_group(dbcsr_distribution_mp( &
                                dbcsr_distribution(matrix_c)))
         IF (numnodes .EQ. 0) THEN
            CALL dbcsr_mp_make_env(mp_env, cart_group, group, nprocs=MAXVAL(npdims))
         ELSE
            CALL dbcsr_mp_make_env(mp_env, cart_group, group, pgrid_dims=npdims)
         END IF
         IF (numnodes < 0) &
            DBCSR_ABORT("Cartesian sides must be greater or equal to 0")
         i_am_alive = dbcsr_mp_active(mp_env)
         alive: IF (i_am_alive) THEN
            npdims(1) = dbcsr_mp_nprows(mp_env)
            npdims(2) = dbcsr_mp_npcols(mp_env)
            group = dbcsr_mp_group(mp_env)
            CALL mp_environ(numnodes, mynode, group)
            ! Row & column distributions
            CALL dbcsr_dist_bin(row_dist_a, &
                                dbcsr_nblkrows_total(matrix_a), npdims(1), &
                                dbcsr_row_block_sizes(matrix_a))
            CALL dbcsr_dist_bin(col_dist_a, &
                                dbcsr_nblkcols_total(matrix_a), npdims(2), &
                                dbcsr_col_block_sizes(matrix_a))
            CALL dbcsr_dist_bin(row_dist_b, &
                                dbcsr_nblkrows_total(matrix_b), npdims(1), &
                                dbcsr_row_block_sizes(matrix_b))
            CALL dbcsr_dist_bin(col_dist_b, &
                                dbcsr_nblkcols_total(matrix_b), npdims(2), &
                                dbcsr_col_block_sizes(matrix_b))
            CALL dbcsr_dist_bin(row_dist_c, &
                                dbcsr_nblkrows_total(matrix_c), npdims(1), &
                                dbcsr_row_block_sizes(matrix_c))
            CALL dbcsr_dist_bin(col_dist_c, &
                                dbcsr_nblkcols_total(matrix_c), npdims(2), &
                                dbcsr_col_block_sizes(matrix_c))
            CALL dbcsr_distribution_new(dist_a, &
                                        mp_env, row_dist_a, col_dist_a, reuse_arrays=.TRUE.)
            CALL dbcsr_distribution_new(dist_b, &
                                        mp_env, row_dist_b, col_dist_b, reuse_arrays=.TRUE.)
            CALL dbcsr_distribution_new(dist_c, &
                                        mp_env, row_dist_c, col_dist_c, reuse_arrays=.TRUE.)
            ! Redistribute the matrices
            ! A
            CALL dbcsr_create(m_a, "Test for "//TRIM(dbcsr_name(matrix_a)), &
                              dist_a, dbcsr_type_no_symmetry, &
                              row_blk_size_obj=matrix_a%row_blk_size, &
                              col_blk_size_obj=matrix_a%col_blk_size, &
                              data_type=dbcsr_get_data_type(matrix_a))
            CALL dbcsr_distribution_release(dist_a)
            CALL dbcsr_redistribute(matrix_a, m_a)
            ! B
            CALL dbcsr_create(m_b, "Test for "//TRIM(dbcsr_name(matrix_b)), &
                              dist_b, dbcsr_type_no_symmetry, &
                              row_blk_size_obj=matrix_b%row_blk_size, &
                              col_blk_size_obj=matrix_b%col_blk_size, &
                              data_type=dbcsr_get_data_type(matrix_b))
            CALL dbcsr_distribution_release(dist_b)
            CALL dbcsr_redistribute(matrix_b, m_b)
            ! C
            CALL dbcsr_create(m_c, "Test for "//TRIM(dbcsr_name(matrix_c)), &
                              dist_c, dbcsr_type_no_symmetry, &
                              row_blk_size_obj=matrix_c%row_blk_size, &
                              col_blk_size_obj=matrix_c%col_blk_size, &
                              data_type=dbcsr_get_data_type(matrix_c))
            CALL dbcsr_distribution_release(dist_c)
            CALL dbcsr_redistribute(matrix_c, m_c)
            CALL dbcsr_copy(m_c_reserve, m_c)
            ! Perform multiply
            loops: DO loop_iter = 1, n_loops
               CALL dbcsr_release(m_c)
               CALL dbcsr_copy(m_c, m_c_reserve)
               CALL mp_sync(group)
               t1 = -m_walltime()
               IF (PRESENT(limits)) THEN
                  IF (eps .LE. -0.0_dp) THEN
                     CALL dbcsr_multiply(transa, transb, alpha, &
                                         m_a, m_b, beta, m_c, &
                                         first_row=limits(1), &
                                         last_row=limits(2), &
                                         first_column=limits(3), &
                                         last_column=limits(4), &
                                         first_k=limits(5), &
                                         last_k=limits(6), &
                                         retain_sparsity=retain_sparsity, flop=flop)
                  ELSE
                     CALL dbcsr_multiply(transa, transb, alpha, &
                                         m_a, m_b, beta, m_c, &
                                         first_row=limits(1), &
                                         last_row=limits(2), &
                                         first_column=limits(3), &
                                         last_column=limits(4), &
                                         first_k=limits(5), &
                                         last_k=limits(6), &
                                         retain_sparsity=retain_sparsity, flop=flop, &
                                         filter_eps=eps)
                  END IF
               ELSE
                  IF (eps .LE. -0.0_dp) THEN
                     CALL dbcsr_multiply(transa, transb, alpha, &
                                         m_a, m_b, beta, m_c, &
                                         retain_sparsity=retain_sparsity, flop=flop)
                  ELSE
                     CALL dbcsr_multiply(transa, transb, alpha, &
                                         m_a, m_b, beta, m_c, &
                                         retain_sparsity=retain_sparsity, flop=flop, &
                                         filter_eps=eps)
                  END IF
               END IF
               t1 = t1 + m_walltime()
               t2 = t2 + t1
               flop_sum = flop_sum + flop
               !
               CALL mp_max(t1, group)
               CALL mp_sum(flop, group)
               t1 = MAX(t1, EPSILON(t1))
               flops_all = REAL(flop, KIND=real_8)/t1/numnodes/(1024*1024)
               IF (io_unit .GT. 0) THEN
                  WRITE (io_unit, '(A,I5,A,I5,A,F12.3,A,I9,A)') &
                     " loop ", loop_iter, " with ", numnodes, " MPI ranks: using ", t1, "s ", INT(flops_all), " Mflops/rank"
                  CALL m_flush(io_unit)
               END IF
               IF (loop_iter .EQ. n_loops .OR. always_checksum) THEN
                  cs = dbcsr_checksum(m_c)
                  cs_pos = dbcsr_checksum(m_c, pos=.TRUE.)
                  IF (io_unit > 0) THEN
                     WRITE (io_unit, *) "Final checksums", cs, cs_pos
                  END IF
               END IF
            END DO loops
            ! Release
            CALL dbcsr_mp_release(mp_env)
            CALL dbcsr_release(m_a)
            CALL dbcsr_release(m_b)
            CALL dbcsr_release(m_c)
            CALL dbcsr_release(m_c_reserve)
         END IF alive
         CALL mp_comm_free(cart_group)
      END DO p_sizes
      CALL timestop(error_handle)
   END SUBROUTINE test_multiplies_multiproc

END MODULE dbcsr_tests
