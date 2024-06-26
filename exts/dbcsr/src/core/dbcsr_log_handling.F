!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_log_handling
   !! various routines to log and control the output.
   !! The idea is that decisions about where to log should not be done in
   !! the code that generates the log, but should be globally changeable
   !! a central place.
   !! So some care has been taken to have enough information about the
   !! place from where the log comes so that in the future intelligent and
   !! flexible decisions can be taken by the logger, without having to change
   !! other code.
   !! @note
   !! contains also routines to convert to a string.
   !! in my idea they should have been with variable length,
   !! (i.e. they should have returned a trim(adjustl(actual_result)))
   !! As a logger should be robust, at the moment I have given up.
   !! At the moment logging and output refer to the same object
   !! (dbcsr_logger_type)
   !! as these are actually different it might be better to separate them
   !! (they have already separate routines in a separate module
   !! @see dbcsr_output_handling).
   !! some practices (use of print *, no dbcsr_error_type,
   !! manual retain release of some objects) are dictated by the need to
   !! have minimal dependency
   !! @endnote
   !!
   !! @see dbcsr_error_handling
   !! @version 12.2001

   USE dbcsr_files, ONLY: close_file, &
                          open_file
   USE dbcsr_iter_types, ONLY: dbcsr_iteration_info_create, &
                               dbcsr_iteration_info_release, &
                               dbcsr_iteration_info_retain, &
                               dbcsr_iteration_info_type
   USE dbcsr_kinds, ONLY: default_path_length, &
                          default_string_length, &
                          dp
   USE dbcsr_machine, ONLY: default_output_unit, &
                            m_getpid, &
                            m_hostnm
   USE dbcsr_methods, ONLY: dbcsr_mp_release
   USE dbcsr_string_utilities, ONLY: compress
   USE dbcsr_timings, ONLY: print_stack
   USE dbcsr_types, ONLY: dbcsr_mp_obj
#include "base/dbcsr_base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   !API types
   PUBLIC :: dbcsr_logger_type, dbcsr_logger_p_type
   !API parameter vars
   PUBLIC :: dbcsr_note_level, dbcsr_warning_level, dbcsr_failure_level, dbcsr_fatal_level
   !API default loggers
   PUBLIC :: dbcsr_get_default_logger, dbcsr_add_default_logger, dbcsr_rm_default_logger, &
             dbcsr_default_logger_stack_size
   !API logger routines
   PUBLIC :: dbcsr_logger_create, dbcsr_logger_retain, dbcsr_logger_release, &
             dbcsr_logger_would_log, dbcsr_logger_set, dbcsr_logger_get_default_unit_nr, &
             dbcsr_logger_get_default_io_unit, dbcsr_logger_get_unit_nr, &
             dbcsr_logger_set_log_level, dbcsr_logger_generate_filename, &
             dbcsr_to_string

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_log_handling'
   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .FALSE.

   !! level of an error
   INTEGER, PARAMETER          :: dbcsr_fatal_level = 3
   !! level of a failure
   INTEGER, PARAMETER          :: dbcsr_failure_level = 2
   !! level of a warning
   INTEGER, PARAMETER          :: dbcsr_warning_level = 1
   !! level of a note
   INTEGER, PARAMETER          :: dbcsr_note_level = 0

   !! a generic function to trasform different types to strings
   INTERFACE dbcsr_to_string
      MODULE PROCEDURE dbcsr_int_to_string, dbcsr_real_dp_to_string, dbcsr_logical_to_string
   END INTERFACE

   TYPE dbcsr_logger_type
      !! type of a logger, at the moment it contains just a print level
      !! starting at which level it should be logged
      !! (0 note, 1 warning, 2 failure, 3 fatal)
      !! it could be expanded with the ability to focus on one or more
      !! module/object/thread/processor
      !! @note
      !! This should be private, but as the output functions have been
      !! moved to another module and there is no "friend" keyword, they
      !! are public.
      !! DO NOT USE THE INTERNAL COMPONENTS DIRECTLY!!!

      INTEGER :: id_nr, ref_count
         !! unique number to identify the logger
         !! reference count (see cp2k/doc/ReferenceCounting.html)
      INTEGER :: print_level
         !! the level starting at which something gets printed
      INTEGER :: default_local_unit_nr
         !! default unit for local logging (-1 if not yet initialized). Local logging guarantee to each task its own file.
      INTEGER :: default_global_unit_nr
         !! default unit for global logging (-1 if not yet initialized). This unit is valid only on the processor with
         !! %mp_env%mp%mynode==%mv_env%mp%source.
      LOGICAL :: close_local_unit_on_dealloc, close_global_unit_on_dealloc
         !! if the local unit should be closed when this logger is deallocated
         !! whether the global unit should be closed when this logger is deallocated
      CHARACTER(len=default_string_length)  :: suffix
         !! a short string that is used as suffix in all the filenames created by this logger. Can be used to guarantee the
         !! uniqueness of generated filename
      CHARACTER(len=default_path_length)    :: local_filename, global_filename
         !! the root of the name of the file used for local logging (can be different from the name of the file corresponding to
         !! default_local_unit_nr, only the one used if the unit needs to be opened)
         !! the root of the name of the file used for global logging (can be different from the name of the file corresponding to
         !! default_global_unit_nr, only the one used if the unit needs to be opened)
      TYPE(dbcsr_mp_obj)                    :: mp_env
         !! the parallel environment for the output.
      TYPE(dbcsr_iteration_info_type), POINTER :: iter_info
   END TYPE dbcsr_logger_type

   TYPE dbcsr_logger_p_type
      TYPE(dbcsr_logger_type), POINTER :: p => Null()
   END TYPE dbcsr_logger_p_type

! **************************************************************************************************
   TYPE default_logger_stack_type
      TYPE(dbcsr_logger_type), POINTER :: dbcsr_default_logger => Null()
   END TYPE default_logger_stack_type

   INTEGER, PRIVATE            :: stack_pointer = 0
   INTEGER, PARAMETER, PRIVATE :: max_stack_pointer = 10
   TYPE(default_logger_stack_type), SAVE, DIMENSION(max_stack_pointer) ::  default_logger_stack

   INTEGER, SAVE, PRIVATE :: last_logger_id_nr = 0

CONTAINS

   FUNCTION dbcsr_default_logger_stack_size() RESULT(res)
      INTEGER                                            :: res

      res = stack_pointer
   END FUNCTION dbcsr_default_logger_stack_size

   SUBROUTINE dbcsr_add_default_logger(logger)
      !! adds a default logger.
      !! MUST be called before logging occurs
      !! @note
      !! increments a stack of default loggers the latest one will be
      !! available within the program

      TYPE(dbcsr_logger_type), POINTER                   :: logger

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_add_default_logger', &
                                     routineP = moduleN//':'//routineN

      IF (stack_pointer + 1 > max_stack_pointer) THEN
         CALL dbcsr_abort(__LOCATION__, routineP// &
                          "too many default loggers, increase max_stack_pointer in "//moduleN)
      END IF

      stack_pointer = stack_pointer + 1
      NULLIFY (default_logger_stack(stack_pointer)%dbcsr_default_logger)

      default_logger_stack(stack_pointer)%dbcsr_default_logger => logger
      CALL dbcsr_logger_retain(logger)

   END SUBROUTINE dbcsr_add_default_logger

   SUBROUTINE dbcsr_rm_default_logger()
      !! the cousin of dbcsr_add_default_logger, decrements the stack, so that
      !! the default logger is what it has
      !! been

      IF (stack_pointer - 1 < 0) THEN
         CALL dbcsr_abort(__LOCATION__, moduleN//":dbcsr_rm_default_logger"// &
                          "can not destroy default logger "//moduleN)
      END IF

      CALL dbcsr_logger_release(default_logger_stack(stack_pointer)%dbcsr_default_logger)
      NULLIFY (default_logger_stack(stack_pointer)%dbcsr_default_logger)
      stack_pointer = stack_pointer - 1

   END SUBROUTINE dbcsr_rm_default_logger

   FUNCTION dbcsr_get_default_logger() RESULT(res)
      !! returns the default logger
      !! @note
      !! initializes the default loggers if necessary

      TYPE(dbcsr_logger_type), POINTER                   :: res

      IF (.NOT. stack_pointer > 0) THEN
         CALL dbcsr_abort(__LOCATION__, "dbcsr_log_handling:dbcsr_get_default_logger"// &
                          "default logger not yet initialized (CALL dbcsr_init_default_logger)")
      END IF
      res => default_logger_stack(stack_pointer)%dbcsr_default_logger
      IF (.NOT. ASSOCIATED(res)) THEN
         CALL dbcsr_abort(__LOCATION__, "dbcsr_log_handling:dbcsr_get_default_logger"// &
                          "default logger is null (released too much ?)")
      END IF
   END FUNCTION dbcsr_get_default_logger

! ================== log ==================

   SUBROUTINE dbcsr_logger_create(logger, mp_env, print_level, &
                                  default_global_unit_nr, default_local_unit_nr, global_filename, &
                                  local_filename, close_global_unit_on_dealloc, iter_info, &
                                  close_local_unit_on_dealloc, suffix, template_logger)
      !! initializes a logger
      !! @note
      !! the handling of *_filename, default_*_unit_nr, close_*_unit_on_dealloc
      !! tries to take the right decision with different inputs, and thus is a
      !! little complex.

      TYPE(dbcsr_logger_type), POINTER                   :: logger
         !! the logger to initialize
      TYPE(dbcsr_mp_obj), OPTIONAL                       :: mp_env
         !! the parallel environment (this is most likely the global parallel environment
      INTEGER, INTENT(in), OPTIONAL                      :: print_level, default_global_unit_nr, &
                                                            default_local_unit_nr
         !! the level starting with which something is written (defaults to dbcsr_note_level)
         !! the default unit_nr for output (if not given, and no file is given defaults to the standard output)
         !! the default unit number for local (i.e. task) output. If not given defaults to a out.taskid file created upon
      CHARACTER(len=*), INTENT(in), OPTIONAL             :: global_filename, local_filename
         !! a new file to open (can be given instead of the global_unit_nr)
         !! a new file to open (with suffix and mp_env%mp%mynode appended). Can be given instead of the default_local_unit_nr). the
         !! file is created only upon the first local logging request
      LOGICAL, INTENT(in), OPTIONAL                      :: close_global_unit_on_dealloc
         !! if the unit should be closed when the logger is deallocated (defaults to true if a local_filename is given, to false
         !! otherwise)
      TYPE(dbcsr_iteration_info_type), OPTIONAL, POINTER :: iter_info
      LOGICAL, INTENT(in), OPTIONAL                      :: close_local_unit_on_dealloc
         !! if the unit should be closed when the logger is deallocated (defaults to true)
      CHARACTER(len=*), INTENT(in), OPTIONAL             :: suffix
         !! the suffix that should be added to all the generated filenames
      TYPE(dbcsr_logger_type), OPTIONAL, POINTER         :: template_logger
         !! a logger from where to take the unspecified things

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_create', &
                                     routineP = moduleN//':'//routineN

      INTEGER                                            :: stat

      ALLOCATE (logger, stat=stat)
      IF (stat /= 0) &
         DBCSR_ABORT(routineP//" could not ALLOCATE a logger")

      NULLIFY (logger%iter_info)
      logger%ref_count = 1
      last_logger_id_nr = last_logger_id_nr + 1
      logger%id_nr = last_logger_id_nr

      IF (PRESENT(template_logger)) THEN
         IF (template_logger%ref_count < 1) &
            DBCSR_ABORT(routineP//" template_logger%ref_count<1")
         logger%print_level = template_logger%print_level
         logger%default_global_unit_nr = template_logger%default_global_unit_nr
         logger%close_local_unit_on_dealloc = template_logger%close_local_unit_on_dealloc
         IF (logger%close_local_unit_on_dealloc) THEN
            logger%default_local_unit_nr = -1
         ELSE
            logger%default_local_unit_nr = template_logger%default_local_unit_nr
         END IF
         logger%close_global_unit_on_dealloc = template_logger%close_global_unit_on_dealloc
         IF (logger%close_global_unit_on_dealloc) THEN
            logger%default_global_unit_nr = -1
         ELSE
            logger%default_global_unit_nr = template_logger%default_global_unit_nr
         END IF
         logger%local_filename = template_logger%local_filename
         logger%global_filename = template_logger%global_filename
         logger%mp_env = template_logger%mp_env
         logger%suffix = template_logger%suffix
         logger%iter_info => template_logger%iter_info
      ELSE
         ! create a file if nothing is specified, one can also get the unit from the default logger
         ! which should have something reasonable as the argument is required in that case
         logger%default_global_unit_nr = -1
         logger%close_global_unit_on_dealloc = .TRUE.
         logger%local_filename = "localLog"
         logger%global_filename = "mainLog"
         logger%print_level = dbcsr_note_level
         ! generate a file for default local logger
         ! except the ionode that should write to the default global logger
         logger%default_local_unit_nr = -1
         logger%close_local_unit_on_dealloc = .TRUE.
         logger%suffix = ""
      END IF
      IF (PRESENT(mp_env)) logger%mp_env = mp_env
      IF (.NOT. ASSOCIATED(logger%mp_env%mp)) &
         DBCSR_ABORT(routineP//" mp env not associated")

      IF (logger%mp_env%mp%refcount < 1) &
         DBCSR_ABORT(routineP//" mp_env%ref_count<1")
      logger%mp_env%mp%refcount = logger%mp_env%mp%refcount + 1

      IF (PRESENT(print_level)) logger%print_level = print_level

      IF (PRESENT(default_global_unit_nr)) &
         logger%default_global_unit_nr = default_global_unit_nr
      IF (PRESENT(global_filename)) THEN
         logger%global_filename = global_filename
         logger%close_global_unit_on_dealloc = .TRUE.
         logger%default_global_unit_nr = -1
      END IF
      IF (PRESENT(close_global_unit_on_dealloc)) THEN
         logger%close_global_unit_on_dealloc = close_global_unit_on_dealloc
         IF (PRESENT(default_global_unit_nr) .AND. PRESENT(global_filename) .AND. &
             (.NOT. close_global_unit_on_dealloc)) THEN
            logger%default_global_unit_nr = default_global_unit_nr
         END IF
      END IF

      IF (PRESENT(default_local_unit_nr)) &
         logger%default_local_unit_nr = default_local_unit_nr
      IF (PRESENT(local_filename)) THEN
         logger%local_filename = local_filename
         logger%close_local_unit_on_dealloc = .TRUE.
         logger%default_local_unit_nr = -1
      END IF
      IF (PRESENT(suffix)) logger%suffix = suffix

      IF (PRESENT(close_local_unit_on_dealloc)) THEN
         logger%close_local_unit_on_dealloc = close_local_unit_on_dealloc
         IF (PRESENT(default_local_unit_nr) .AND. PRESENT(local_filename) .AND. &
             (.NOT. close_local_unit_on_dealloc)) THEN
            logger%default_local_unit_nr = default_local_unit_nr
         END IF
      END IF

      IF (logger%default_local_unit_nr == -1) THEN
         IF (logger%mp_env%mp%mynode == logger%mp_env%mp%source) THEN
            logger%default_local_unit_nr = logger%default_global_unit_nr
            logger%close_local_unit_on_dealloc = .FALSE.
         END IF
      END IF
      IF (PRESENT(iter_info)) logger%iter_info => iter_info
      IF (ASSOCIATED(logger%iter_info)) THEN
         CALL dbcsr_iteration_info_retain(logger%iter_info)
      ELSE
         CALL dbcsr_iteration_info_create(logger%iter_info, "")
      END IF
   END SUBROUTINE dbcsr_logger_create

   SUBROUTINE dbcsr_logger_retain(logger)
      !! retains the given logger (to be called to keep a shared copy of
      !! the logger)

      TYPE(dbcsr_logger_type), POINTER                   :: logger
         !! the logger to retain

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_retain', &
                                     routineP = moduleN//':'//routineN

      IF (.NOT. ASSOCIATED(logger)) &
         DBCSR_ABORT(routineP//" logger not associated")
      IF (logger%ref_count < 1) &
         DBCSR_ABORT(routineP//" logger%ref_count<1")
      logger%ref_count = logger%ref_count + 1
   END SUBROUTINE dbcsr_logger_retain

   SUBROUTINE dbcsr_logger_release(logger)
      !! releases this logger

      TYPE(dbcsr_logger_type), POINTER                   :: logger
         !! the logger to release

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_release', &
                                     routineP = moduleN//':'//routineN

      IF (ASSOCIATED(logger)) THEN
         IF (logger%ref_count < 1) &
            DBCSR_ABORT(routineP//" logger%ref_count<1")
         logger%ref_count = logger%ref_count - 1
         IF (logger%ref_count == 0) THEN
            IF (logger%close_global_unit_on_dealloc .AND. &
                logger%default_global_unit_nr >= 0) THEN
               CALL close_file(logger%default_global_unit_nr)
               logger%close_global_unit_on_dealloc = .FALSE.
               logger%default_global_unit_nr = -1
            END IF
            IF (logger%close_local_unit_on_dealloc .AND. &
                logger%default_local_unit_nr >= 0) THEN
               CALL close_file(logger%default_local_unit_nr)
               logger%close_local_unit_on_dealloc = .FALSE.
               logger%default_local_unit_nr = -1
            END IF
            CALL dbcsr_mp_release(logger%mp_env)
            CALL dbcsr_iteration_info_release(logger%iter_info)
            DEALLOCATE (logger)
         END IF
      END IF
   END SUBROUTINE dbcsr_logger_release

   FUNCTION dbcsr_logger_would_log(logger, level) RESULT(res)
      !! this function can be called to check if the logger would log
      !! a message with the given level from the given source
      !! you should use this function if you do direct logging
      !! (without using dbcsr_logger_log), or if you want to know if the generation
      !! of some costly log info is necessary

      TYPE(dbcsr_logger_type), POINTER                   :: logger
         !! the logger you want to log in
      INTEGER, INTENT(in)                                :: level
         !! describes the of the message: dbcsr_fatal_level(3), dbcsr_failure_level(2), dbcsr_warning_level(1), dbcsr_note_level(0).
      LOGICAL                                            :: res

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_would_log', &
                                     routineP = moduleN//':'//routineN

      TYPE(dbcsr_logger_type), POINTER                   :: lggr

      lggr => logger
      IF (.NOT. ASSOCIATED(lggr)) lggr => dbcsr_get_default_logger()
      IF (lggr%ref_count < 1) &
         DBCSR_ABORT(routineP//" logger%ref_count<1")

      res = level >= lggr%print_level
   END FUNCTION dbcsr_logger_would_log

   FUNCTION dbcsr_logger_get_unit_nr(logger, local) RESULT(res)
      !! returns the unit nr for the requested kind of log.

      TYPE(dbcsr_logger_type), POINTER                   :: logger
         !! the logger you want to log in
      LOGICAL, INTENT(in), OPTIONAL                      :: local
         !! if true returns a local logger (one per task), otherwise returns a global logger (only the process with
         !! mp_env%mp%mynode== mp_env%mp%source should write to the global logger). Defaults to false
      INTEGER                                            :: res

      res = dbcsr_logger_get_default_unit_nr(logger, local=local)
   END FUNCTION dbcsr_logger_get_unit_nr

   FUNCTION dbcsr_logger_get_default_io_unit(logger) RESULT(res)
      !! returns the unit nr for the ionode (-1 on all other processors)
      !! skips as well checks if the procs calling this function is not the ionode

      TYPE(dbcsr_logger_type), OPTIONAL, POINTER         :: logger
         !! the logger you want to log in
      INTEGER                                            :: res

      TYPE(dbcsr_logger_type), POINTER                   :: local_logger

      IF (PRESENT(logger)) THEN
         local_logger => logger
      ELSE IF (stack_pointer == 0) THEN
         res = -1 ! edge case: default logger not yet/anymore available
         RETURN
      ELSE
         local_logger => dbcsr_get_default_logger()
      END IF

      res = dbcsr_logger_get_default_unit_nr(local_logger, local=.FALSE., skip_not_ionode=.TRUE.)
   END FUNCTION dbcsr_logger_get_default_io_unit

! *************************** dbcsr_logger_type settings ***************************

   SUBROUTINE dbcsr_logger_set_log_level(logger, level)
      !! changes the logging level. Log messages with a level less than the one
      !! given wo not be printed.

      TYPE(dbcsr_logger_type), POINTER                   :: logger
         !! the logger to change
      INTEGER, INTENT(in)                                :: level
         !! the new logging level for the logger

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_set_log_level', &
                                     routineP = moduleN//':'//routineN

      IF (.NOT. ASSOCIATED(logger)) &
         DBCSR_ABORT(routineP//" logger not associated")
      IF (logger%ref_count < 1) &
         DBCSR_ABORT(routineP//" logger%ref_count<1")
      logger%print_level = level
   END SUBROUTINE dbcsr_logger_set_log_level

   RECURSIVE FUNCTION dbcsr_logger_get_default_unit_nr(logger, local, skip_not_ionode) RESULT(res)
      !! asks the default unit number of the given logger.
      !! try to use dbcsr_logger_get_unit_nr

      TYPE(dbcsr_logger_type), OPTIONAL, POINTER         :: logger
         !! the logger you want info from
      LOGICAL, INTENT(in), OPTIONAL                      :: local, skip_not_ionode
         !! if you want the local unit nr (defaults to false)
      INTEGER                                            :: res

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_get_default_unit_nr', &
                                     routineP = moduleN//':'//routineN

      CHARACTER(len=default_path_length)                 :: filename, host_name
      INTEGER                                            :: iostat, pid
      LOGICAL                                            :: loc, skip
      TYPE(dbcsr_logger_type), POINTER                   :: lggr

      loc = .TRUE.
      skip = .FALSE.
      IF (PRESENT(logger)) THEN
         lggr => logger
      ELSE
         NULLIFY (lggr)
      END IF
      IF (.NOT. ASSOCIATED(lggr)) lggr => dbcsr_get_default_logger()
      IF (lggr%ref_count < 1) &
         DBCSR_ABORT(routineP//" logger%ref_count<1")

      IF (PRESENT(local)) loc = local
      IF (PRESENT(skip_not_ionode)) skip = skip_not_ionode
      IF (.NOT. loc) THEN
         IF (lggr%default_global_unit_nr <= 0) THEN
            IF (lggr%mp_env%mp%mynode == lggr%mp_env%mp%source) THEN
               CALL dbcsr_logger_generate_filename(lggr, filename, lggr%global_filename, &
                                                   ".out", local=.FALSE.)
               CALL open_file(TRIM(filename), file_status="unknown", &
                              file_action="WRITE", file_position="APPEND", &
                              unit_number=lggr%default_global_unit_nr)
            ELSE IF (.NOT. skip) THEN
               lggr%default_global_unit_nr = dbcsr_logger_get_default_unit_nr(lggr, .TRUE.)
               lggr%close_global_unit_on_dealloc = .FALSE.
            ELSE
               lggr%default_global_unit_nr = -1
               lggr%close_global_unit_on_dealloc = .FALSE.
            END IF
         END IF
         IF ((lggr%mp_env%mp%mynode /= lggr%mp_env%mp%source) .AND. (.NOT. skip)) THEN
            WRITE (UNIT=lggr%default_global_unit_nr, FMT='(/,T2,A)', IOSTAT=iostat) &
               ' *** WARNING non ionode asked for global logger ***'
            IF (iostat /= 0) THEN
               CALL m_getpid(pid)
               CALL m_hostnm(host_name)
               PRINT *, " *** Error trying to WRITE to the local logger ***"
               PRINT *, " *** MPI_id           = ", lggr%mp_env%mp%mynode
               PRINT *, " *** MPI_Communicator = ", lggr%mp_env%mp%mp_group%get_handle()
               PRINT *, " *** PID              = ", pid
               PRINT *, " *** Hostname         = "//TRIM(host_name)
               CALL print_stack(default_output_unit)
            ELSE
               CALL print_stack(lggr%default_global_unit_nr)
            END IF
         END IF
         res = lggr%default_global_unit_nr
      ELSE
         IF (lggr%default_local_unit_nr <= 0) THEN
            CALL dbcsr_logger_generate_filename(lggr, filename, lggr%local_filename, &
                                                ".out", local=.TRUE.)
            CALL open_file(TRIM(filename), file_status="unknown", &
                           file_action="WRITE", &
                           file_position="APPEND", &
                           unit_number=lggr%default_local_unit_nr)
            WRITE (UNIT=lggr%default_local_unit_nr, FMT='(/,T2,A,I0,A,I0,A)', IOSTAT=iostat) &
               '*** Local logger file of MPI task ', lggr%mp_env%mp%mynode, &
               ' in communicator ', lggr%mp_env%mp%mp_group%get_handle(), ' ***'
            IF (iostat == 0) THEN
               CALL m_getpid(pid)
               CALL m_hostnm(host_name)
               WRITE (UNIT=lggr%default_local_unit_nr, FMT='(T2,A,I0)', IOSTAT=iostat) &
                  '*** PID      = ', pid, &
                  '*** Hostname = '//host_name
               CALL print_stack(lggr%default_local_unit_nr)
            END IF
            IF (iostat /= 0) THEN
               CALL m_getpid(pid)
               CALL m_hostnm(host_name)
               PRINT *, " *** Error trying to WRITE to the local logger ***"
               PRINT *, " *** MPI_id           = ", lggr%mp_env%mp%mynode
               PRINT *, " *** MPI_Communicator = ", lggr%mp_env%mp%mp_group%get_handle()
               PRINT *, " *** PID              = ", pid
               PRINT *, " *** Hostname         = "//TRIM(host_name)
               CALL print_stack(default_output_unit)
            END IF

         END IF
         res = lggr%default_local_unit_nr
      END IF
   END FUNCTION dbcsr_logger_get_default_unit_nr

   SUBROUTINE dbcsr_logger_generate_filename(logger, res, root, postfix, &
                                             local)
      !! generates a unique filename (ie adding eventual suffixes and
      !! process ids)
      !! @note
      !! this should be a function returning a variable length string.
      !! All spaces are moved to the end of the string.
      !! Not fully optimized: result must be a little longer than the
      !! resulting compressed filename

      TYPE(dbcsr_logger_type), POINTER                   :: logger
      CHARACTER(len=*), INTENT(inout)                    :: res
         !! the resulting string
      CHARACTER(len=*), INTENT(in)                       :: root, postfix
         !! the start of filename
         !! the end of the name
      LOGICAL, INTENT(in), OPTIONAL                      :: local
         !! if the name should be local to this task (defaults to false)

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_generate_filename', &
                                     routineP = moduleN//':'//routineN

      LOGICAL                                            :: loc
      TYPE(dbcsr_logger_type), POINTER                   :: lggr

      loc = .FALSE.
      res = ' '
      lggr => logger

      IF (.NOT. ASSOCIATED(lggr)) lggr => dbcsr_get_default_logger()
      IF (lggr%ref_count < 1) &
         DBCSR_ABORT(routineP//" logger%ref_count<1")
      IF (PRESENT(local)) loc = local
      IF (loc) THEN
         res = TRIM(root)//TRIM(lggr%suffix)//'_p'// &
               dbcsr_to_string(lggr%mp_env%mp%mynode)//postfix
      ELSE
         res = TRIM(root)//TRIM(lggr%suffix)//postfix
      END IF
      CALL compress(res, full=.TRUE.)
   END SUBROUTINE dbcsr_logger_generate_filename

   SUBROUTINE dbcsr_logger_set(logger, local_filename, global_filename)
      !! sets various attributes of the given logger

      TYPE(dbcsr_logger_type), POINTER                   :: logger
         !! the logger you want to change
      CHARACTER(len=*), INTENT(in), OPTIONAL             :: local_filename, global_filename
         !! the root of the name of the file used for local logging
         !! the root of the name of the file used for global logging

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_logger_set', &
                                     routineP = moduleN//':'//routineN

      IF (.NOT. ASSOCIATED(logger)) &
         DBCSR_ABORT(routineP//" unassociated logger")
      IF (PRESENT(local_filename)) logger%local_filename = local_filename
      IF (PRESENT(global_filename)) logger%global_filename = global_filename
   END SUBROUTINE dbcsr_logger_set

   FUNCTION dbcsr_int_to_string(i) RESULT(res)
      !! converts an int to a string
      !! (should be a variable length string, but that does not work with
      !! all the compilers)

      INTEGER, INTENT(in)                                :: i
         !! the integer to convert
      CHARACTER(len=6)                                   :: res

      CHARACTER(len=6)                                   :: t_res
      INTEGER                                            :: iostat
      REAL(KIND=dp)                                      :: tmp_r

      iostat = 0
      IF (i > 999999 .OR. i < -99999) THEN
         tmp_r = i
         WRITE (t_res, fmt='(es6.1)', iostat=iostat) tmp_r
      ELSE
         WRITE (t_res, fmt='(i6)', iostat=iostat) i
      END IF
      res = t_res
      IF (iostat /= 0) THEN
         PRINT *, "dbcsr_int_to_string ioerror", iostat
         CALL print_stack(dbcsr_logger_get_default_unit_nr())
      END IF
   END FUNCTION dbcsr_int_to_string

   FUNCTION dbcsr_real_dp_to_string(val) RESULT(res)
      !! convert a double precision real in a string
      !! (should be a variable length string, but that does not work with
      !! all the compilers)

      REAL(KIND=dp), INTENT(in)                          :: val
         !! the number to convert
      CHARACTER(len=11)                                  :: res

      WRITE (res, '(es11.4)') val
   END FUNCTION dbcsr_real_dp_to_string

   FUNCTION dbcsr_logical_to_string(val) RESULT(res)
      !! convert a logical in a string ('T' or 'F')

      LOGICAL, INTENT(in)                                :: val
         !! the number to convert
      CHARACTER(len=1)                                   :: res

      IF (val) THEN
         res = 'T'
      ELSE
         res = 'F'
      END IF
   END FUNCTION dbcsr_logical_to_string

END MODULE dbcsr_log_handling
