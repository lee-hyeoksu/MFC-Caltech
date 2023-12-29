!>
!! @file m_time_steppers.f90
!! @brief Contains module m_time_steppers

#:include 'macros.fpp'

!> @brief The following module features a variety of time-stepping schemes.
!!              Currently, it includes the following Runge-Kutta (RK) algorithms:
!!                   1) 1st Order TVD RK
!!                   2) 2nd Order TVD RK
!!                   3) 3rd Order TVD RK
!!              where TVD designates a total-variation-diminishing time-stepper.
module m_time_steppers

    ! Dependencies =============================================================
    use m_derived_types        !< Definitions of the derived types

    use m_global_parameters    !< Definitions of the global parameters

    use m_rhs                  !< Right-hand-side (RHS) evaluation procedures

    use m_data_output          !< Run-time info & solution data output procedures

    use m_bubbles              !< Bubble dynamics routines

    use m_mpi_proxy            !< Message passing interface (MPI) module proxy

    use m_boundary_conditions

    use m_fftw

    use m_nvtx
    ! ==========================================================================

    implicit none

    type(vector_field), allocatable, dimension(:) :: q_cons_ts !<
    !! Cell-average conservative variables at each time-stage (TS)

    type(scalar_field), allocatable, dimension(:) :: q_prim_vf !<
    !! Cell-average primitive variables at the current time-stage

    type(scalar_field), allocatable, dimension(:) :: rhs_vf !<
    !! Cell-average RHS variables at the current time-stage

    type(vector_field), allocatable, dimension(:) :: q_prim_ts !<
    !! Cell-average primitive variables at consecutive TIMESTEPS

    real(kind(0d0)), allocatable, dimension(:, :, :, :, :) :: rhs_pb

    real(kind(0d0)), allocatable, dimension(:, :, :, :, :) :: rhs_mv

    integer, private :: num_ts !<
    !! Number of time stages in the time-stepping scheme

!$acc declare create(q_cons_ts,q_prim_vf,rhs_vf,q_prim_ts, rhs_mv, rhs_pb)

contains

    !> The computation of parameters, the allocation of memory,
        !!      the association of pointers and/or the execution of any
        !!      other procedures that are necessary to setup the module.
    subroutine s_initialize_time_steppers_module() ! -----------------------

        type(int_bounds_info) :: ix_t, iy_t, iz_t !<
            !! Indical bounds in the x-, y- and z-directions

        integer :: i, j !< Generic loop iterators

        ! Setting number of time-stages for selected time-stepping scheme
        if (time_stepper == 1) then
            num_ts = 1
        elseif (any(time_stepper == (/2, 3/))) then
            num_ts = 2
        end if

        ! Setting the indical bounds in the x-, y- and z-directions
        ix_t%beg = -buff_size; ix_t%end = m + buff_size

        if (n > 0) then
            iy_t%beg = -buff_size; iy_t%end = n + buff_size

            if (p > 0) then
                iz_t%beg = -buff_size; iz_t%end = p + buff_size
            else
                iz_t%beg = 0; iz_t%end = 0
            end if
        else
            iy_t%beg = 0; iy_t%end = 0
            iz_t%beg = 0; iz_t%end = 0
        end if

        ! Allocating the cell-average conservative variables
        @:ALLOCATE(q_cons_ts(1:num_ts))


        do i = 1, num_ts
            @:ALLOCATE(q_cons_ts(i)%vf(1:sys_size))
        end do

        do i = 1, num_ts
            do j = 1, sys_size
                @:ALLOCATE(q_cons_ts(i)%vf(j)%sf(ix_t%beg:ix_t%end, &
                                                iy_t%beg:iy_t%end, &
                                                iz_t%beg:iz_t%end))
            end do
        end do

        ! Allocating the cell-average primitive ts variables
        if (probe_wrt) then
            @:ALLOCATE(q_prim_ts(0:3))

            do i = 0, 3
                @:ALLOCATE(q_prim_ts(i)%vf(1:sys_size))
            end do

            do i = 0, 3
                do j = 1, sys_size
                    @:ALLOCATE(q_prim_ts(i)%vf(j)%sf(ix_t%beg:ix_t%end, &
                                                    iy_t%beg:iy_t%end, &
                                                    iz_t%beg:iz_t%end))
                end do
            end do
        end if

        ! Allocating the cell-average primitive variables
        @:ALLOCATE(q_prim_vf(1:sys_size))
        
        do i = 1, adv_idx%end
            @:ALLOCATE(q_prim_vf(i)%sf(ix_t%beg:ix_t%end, &
                                      iy_t%beg:iy_t%end, &
                                      iz_t%beg:iz_t%end))
        end do

        if (bubbles) then
            do i = bub_idx%beg, bub_idx%end
                @:ALLOCATE(q_prim_vf(i)%sf(ix_t%beg:ix_t%end, &
                                          iy_t%beg:iy_t%end, &
                                          iz_t%beg:iz_t%end))
            end do
        end if

        @:ALLOCATE(pb_ts(1:2))
        !Initialize bubble variables pb and mv at all quadrature nodes for all R0 bins
        if(qbmm .and. (.not. polytropic)) then
            @:ALLOCATE(pb_ts(1)%sf(ix_t%beg:ix_t%end, &
                          iy_t%beg:iy_t%end, &
                          iz_t%beg:iz_t%end, 1:nnode, 1:nb))
            @:ALLOCATE(pb_ts(2)%sf(ix_t%beg:ix_t%end, &
                          iy_t%beg:iy_t%end, &
                          iz_t%beg:iz_t%end, 1:nnode, 1:nb))
            @:ALLOCATE(rhs_pb(ix_t%beg:ix_t%end, &
                          iy_t%beg:iy_t%end, &
                          iz_t%beg:iz_t%end, 1:nnode, 1:nb))
        else if(qbmm .and. polytropic) then
            @:ALLOCATE(pb_ts(1)%sf(ix_t%beg:ix_t%beg + 1, &
                          iy_t%beg:iy_t%beg + 1, &
                          iz_t%beg:iz_t%beg + 1, 1:nnode, 1:nb))
            @:ALLOCATE(pb_ts(2)%sf(ix_t%beg:ix_t%beg + 1, &
                          iy_t%beg:iy_t%beg + 1, &
                          iz_t%beg:iz_t%beg + 1, 1:nnode, 1:nb))
            @:ALLOCATE(rhs_pb(ix_t%beg:ix_t%beg + 1, &
                          iy_t%beg:iy_t%beg + 1, &
                          iz_t%beg:iz_t%beg + 1, 1:nnode, 1:nb))
        end if

        @:ALLOCATE(mv_ts(1:2))

        if(qbmm .and. (.not. polytropic)) then
            @:ALLOCATE(mv_ts(1)%sf(ix_t%beg:ix_t%end, &
                          iy_t%beg:iy_t%end, &
                          iz_t%beg:iz_t%end, 1:nnode, 1:nb))
            @:ALLOCATE(mv_ts(2)%sf(ix_t%beg:ix_t%end, &
                          iy_t%beg:iy_t%end, &
                          iz_t%beg:iz_t%end, 1:nnode, 1:nb))
            @:ALLOCATE(rhs_mv(ix_t%beg:ix_t%end, &
                          iy_t%beg:iy_t%end, &
                          iz_t%beg:iz_t%end, 1:nnode, 1:nb))
        else if(qbmm .and. polytropic) then
            @:ALLOCATE(mv_ts(1)%sf(ix_t%beg:ix_t%beg + 1, &
                          iy_t%beg:iy_t%beg + 1, &
                          iz_t%beg:iz_t%beg + 1, 1:nnode, 1:nb))
            @:ALLOCATE(mv_ts(2)%sf(ix_t%beg:ix_t%beg + 1, &
                          iy_t%beg:iy_t%beg + 1, &
                          iz_t%beg:iz_t%beg + 1, 1:nnode, 1:nb))
            @:ALLOCATE(rhs_mv(ix_t%beg:ix_t%beg + 1, &
                          iy_t%beg:iy_t%beg + 1, &
                          iz_t%beg:iz_t%beg + 1, 1:nnode, 1:nb))
        end if

        if (adv_n) then
            @:ALLOCATE(q_prim_vf(n_idx)%sf(ix_t%beg:ix_t%end, &
                            iy_t%beg:iy_t%end, &
                            iz_t%beg:iz_t%end))
        end if

        if (hypoelasticity) then

            do i = stress_idx%beg, stress_idx%end
                @:ALLOCATE(q_prim_vf(i)%sf(ix_t%beg:ix_t%end, &
                                          iy_t%beg:iy_t%end, &
                                          iz_t%beg:iz_t%end))
            end do
        end if

        if (model_eqns == 3) then
            do i = internalEnergies_idx%beg, internalEnergies_idx%end
                @:ALLOCATE(q_prim_vf(i)%sf(ix_t%beg:ix_t%end, &
                                          iy_t%beg:iy_t%end, &
                                          iz_t%beg:iz_t%end))
            end do
        end if

        ! Allocating the cell-average RHS variables
        @:ALLOCATE(rhs_vf(1:sys_size))

        do i = 1, sys_size
            @:ALLOCATE(rhs_vf(i)%sf(0:m, 0:n, 0:p))
        end do

        ! Opening and writing the header of the run-time information file
        if (proc_rank == 0 .and. run_time_info) then
            call s_open_run_time_information_file()
        end if

    end subroutine s_initialize_time_steppers_module ! ---------------------

    !> 1st order TVD RK time-stepping algorithm
        !! @param t_step Current time step
    subroutine s_1st_order_tvd_rk(t_step, time_avg) ! --------------------------------

        integer, intent(IN) :: t_step
        real(kind(0d0)), intent(INOUT) :: time_avg

        integer :: i, j, k, l, q!< Generic loop iterator
        real(kind(0d0)) :: start, finish
        real(kind(0d0)) :: nR3bar
        
        ! Stage 1 of 1 =====================================================

        call cpu_time(start)

        call nvtxStartRange("Time_Step")

        call s_compute_rhs(q_cons_ts(1)%vf, q_prim_vf, rhs_vf, pb_ts(1)%sf, rhs_pb, mv_ts(1)%sf, rhs_mv, t_step)

#ifdef DEBUG
        print *, 'got rhs'
#endif

        if (run_time_info) then
            call s_write_run_time_information(q_prim_vf, t_step)
        end if

#ifdef DEBUG
        print *, 'wrote runtime info'
#endif

        if (probe_wrt) then
            call s_time_step_cycling(t_step)
        end if

        if (t_step == t_step_stop) return

!$acc parallel loop collapse(4) gang vector default(present)
        do i = 1, sys_size
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        q_cons_ts(1)%vf(i)%sf(j, k, l) = &
                            q_cons_ts(1)%vf(i)%sf(j, k, l) &
                            + dt*rhs_vf(i)%sf(j, k, l)
                    end do
                end do
            end do
        end do
        !Evolve pb and mv for non-polytropic qbmm
        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                pb_ts(1)%sf(j, k, l, q, i) = &
                                      pb_ts(1)%sf(j, k, l, q, i) &
                                    + dt*rhs_pb(j, k, l, q, i)
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                mv_ts(1)%sf(j, k, l, q, i) = &
                                      mv_ts(1)%sf(j, k, l, q, i) &
                                    + dt*rhs_mv(j, k, l, q, i)
                            end do
                        end do
                    end do
                end do
            end do
        end if 

        if (grid_geometry == 3) call s_apply_fourier_filter(q_cons_ts(1)%vf)

        if (model_eqns == 3) call s_pressure_relaxation_procedure(q_cons_ts(1)%vf)

        if (adv_n .and. alter_alpha) then
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        nR3bar = 0d0
                        do i = 1, nb
                            if (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l) < 0) then
                                print *, j,k,l,i,q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)
                                error stop "R < 0"
                            end if
                            if(polytropic) then
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            else
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            end if
                        end do
                        q_cons_ts(1)%vf(alf_idx)%sf(j, k, l) = (4*pi*nR3bar)/(3*q_cons_ts(1)%vf(n_idx)%sf(j, k, l)**2)
                    end do
                end do
            end do
        end if

        call nvtxEndRange

        call cpu_time(finish)

        if (t_step >= 4) then
            time_avg = (abs(finish - start) + (t_step - 4)*time_avg)/(t_step - 3)
        else
            time_avg = 0d0
        end if

        ! ==================================================================

    end subroutine s_1st_order_tvd_rk ! ------------------------------------

    !> 2nd order TVD RK time-stepping algorithm
        !! @param t_step Current time-step
    subroutine s_2nd_order_tvd_rk(t_step, time_avg) ! --------------------------------

        integer, intent(IN) :: t_step
        real(kind(0d0)), intent(INOUT) :: time_avg

        integer :: i, j, k, l, q!< Generic loop iterator
        real(kind(0d0)) :: start, finish
        real(kind(0d0)) :: nR3bar

        ! Stage 1 of 2 =====================================================

        call cpu_time(start)

        call nvtxStartRange("Time_Step")

        call s_compute_rhs(q_cons_ts(1)%vf, q_prim_vf, rhs_vf, pb_ts(1)%sf, rhs_pb, mv_ts(1)%sf, rhs_mv, t_step)

        if (run_time_info) then
            call s_write_run_time_information(q_prim_vf, t_step)
        end if

        if (probe_wrt) then
            call s_time_step_cycling(t_step)
        end if

        if (t_step == t_step_stop) return

!$acc parallel loop collapse(4) gang vector default(present)
        do i = 1, sys_size
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        q_cons_ts(2)%vf(i)%sf(j, k, l) = &
                            q_cons_ts(1)%vf(i)%sf(j, k, l) &
                            + dt*rhs_vf(i)%sf(j, k, l)
                    end do
                end do
            end do
        end do
        !Evolve pb and mv for non-polytropic qbmm
        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                pb_ts(2)%sf(j, k, l, q, i) = &
                                      pb_ts(1)%sf(j, k, l, q, i) &
                                    + dt*rhs_pb(j, k, l, q, i)
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                mv_ts(2)%sf(j, k, l, q, i) = &
                                      mv_ts(1)%sf(j, k, l, q, i) &
                                    + dt*rhs_mv(j, k, l, q, i)
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if (grid_geometry == 3) call s_apply_fourier_filter(q_cons_ts(2)%vf)

        if (model_eqns == 3) call s_pressure_relaxation_procedure(q_cons_ts(2)%vf)

        if (adv_n .and. alter_alpha) then
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        nR3bar = 0d0
                        do i = 1, nb
                            if (q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l) < 0) then
                                print *, j,k,l,i,q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l)
                                error stop "R < 0"
                            end if
                            if(polytropic) then
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            else
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            end if
                        end do
                        q_cons_ts(2)%vf(alf_idx)%sf(j, k, l) = (4*pi*nR3bar)/(3*q_cons_ts(2)%vf(n_idx)%sf(j, k, l)**2)
                    end do
                end do
            enddo
        end if

        ! ==================================================================

        ! Stage 2 of 2 =====================================================

        call s_compute_rhs(q_cons_ts(2)%vf, q_prim_vf, rhs_vf, pb_ts(2)%sf, rhs_pb, mv_ts(2)%sf, rhs_mv,t_step)

!$acc parallel loop collapse(4) gang vector default(present)
        do i = 1, sys_size
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        q_cons_ts(1)%vf(i)%sf(j, k, l) = &
                            (q_cons_ts(1)%vf(i)%sf(j, k, l) &
                             + q_cons_ts(2)%vf(i)%sf(j, k, l) &
                             + dt*rhs_vf(i)%sf(j, k, l))/2d0
                    end do
                end do
            end do
        end do

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                pb_ts(1)%sf(j, k, l, q, i) = &
                                    (pb_ts(1)%sf(j, k, l, q, i) &
                                     +  pb_ts(2)%sf(j, k, l, q, i) &
                                    + dt*rhs_pb(j, k, l, q, i))/2d0
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                mv_ts(1)%sf(j, k, l, q, i) = &
                                    (mv_ts(1)%sf(j, k, l, q, i) &
                                     +  mv_ts(2)%sf(j, k, l, q, i) &
                                    + dt*rhs_mv(j, k, l, q, i))/2d0
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if (grid_geometry == 3) call s_apply_fourier_filter(q_cons_ts(1)%vf)

        if (model_eqns == 3) call s_pressure_relaxation_procedure(q_cons_ts(1)%vf)

        if (adv_n .and. alter_alpha) then
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        nR3bar = 0d0
                        do i = 1, nb
                            if (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l) < 0) then
                                print *, j,k,l,i,q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)
                                error stop "R < 0"
                            end if
                            if(polytropic) then
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            else
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            end if
                        end do
                        q_cons_ts(1)%vf(alf_idx)%sf(j, k, l) = (4*pi*nR3bar)/(3*q_cons_ts(1)%vf(n_idx)%sf(j, k, l)**2)
                    end do
                end do
            end do
        end if

        call nvtxEndRange

        call cpu_time(finish)

        if (t_step >= 4) then
            time_avg = (abs(finish - start) + (t_step - 4)*time_avg)/(t_step - 3)
        else
            time_avg = 0d0
        end if

        ! ==================================================================

    end subroutine s_2nd_order_tvd_rk ! ------------------------------------

    !> 3rd order TVD RK time-stepping algorithm
        !! @param t_step Current time-step
    subroutine s_3rd_order_tvd_rk(t_step, time_avg, dt_in) ! --------------------------------

        integer, intent(IN) :: t_step
        real(kind(0d0)), intent(INOUT) :: time_avg
        real(kind(0d0)), intent(IN) :: dt_in

        integer :: i, j, k, l, q 
        real(kind(0d0)) :: ts_error, denom, error_fraction, time_step_factor !< Generic loop iterator
        real(kind(0d0)) :: start, finish
        real(kind(0d0)) :: nR3bar

        type(int_bounds_info) :: ix, iy, iz
        type(vector_field) :: gm_alpha_qp  !<

        ! Stage 1 of 3 =====================================================

        call cpu_time(start)

        call nvtxStartRange("Time_Step")

        call s_compute_rhs(q_cons_ts(1)%vf, q_prim_vf, rhs_vf, pb_ts(1)%sf, rhs_pb, mv_ts(1)%sf, rhs_mv, t_step)

        if (run_time_info) then
            call s_write_run_time_information(q_prim_vf, t_step)
        end if

        if (probe_wrt) then
            call s_time_step_cycling(t_step)
        end if

        if (t_step == t_step_stop) return

!$acc parallel loop collapse(4) gang vector default(present)
        do i = 1, sys_size
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        q_cons_ts(2)%vf(i)%sf(j, k, l) = &
                            q_cons_ts(1)%vf(i)%sf(j, k, l) &
                            + dt_in*rhs_vf(i)%sf(j, k, l)
                    end do
                end do
            end do
        end do
        !Evolve pb and mv for non-polytropic qbmm
        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                pb_ts(2)%sf(j, k, l, q, i) = &
                                    pb_ts(1)%sf(j, k, l, q, i) &
                                    + dt_in*rhs_pb(j, k, l, q, i)
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                mv_ts(2)%sf(j, k, l, q, i) = &
                                    mv_ts(1)%sf(j, k, l, q, i) &
                                    + dt_in*rhs_mv(j, k, l, q, i)
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if (grid_geometry == 3) call s_apply_fourier_filter(q_cons_ts(2)%vf)

        if (model_eqns == 3) call s_pressure_relaxation_procedure(q_cons_ts(2)%vf)

        if (adv_n .and. alter_alpha) then
            !$acc parallel loop collapse(3) gang vector default(present)
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        nR3bar = 0d0
                        !$acc loop seq
                        do i = 1, nb
                            if(polytropic) then
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            else
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            end if
                        end do
                        q_cons_ts(2)%vf(alf_idx)%sf(j, k, l) = (4*pi*nR3bar)/(3*q_cons_ts(2)%vf(n_idx)%sf(j, k, l)**2)
                    end do
                end do
            enddo
        end if

        ! ==================================================================

        ! Stage 2 of 3 =====================================================

        call s_compute_rhs(q_cons_ts(2)%vf, q_prim_vf, rhs_vf, pb_ts(2)%sf, rhs_pb, mv_ts(2)%sf, rhs_mv, t_step)

!$acc parallel loop collapse(4) gang vector default(present)
        do i = 1, sys_size
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        q_cons_ts(2)%vf(i)%sf(j, k, l) = &
                            (3d0*q_cons_ts(1)%vf(i)%sf(j, k, l) &
                             + q_cons_ts(2)%vf(i)%sf(j, k, l) &
                             + dt_in*rhs_vf(i)%sf(j, k, l))/4d0
                    end do
                end do
            end do
        end do

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                pb_ts(2)%sf(j, k, l, q, i) = &
                                    (3d0*pb_ts(1)%sf(j, k, l, q, i) &
                                     +  pb_ts(2)%sf(j, k, l, q, i) &
                                    + dt_in*rhs_pb(j, k, l, q, i))/4d0
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                mv_ts(2)%sf(j, k, l, q, i) = &
                                    (3d0*mv_ts(1)%sf(j, k, l, q, i) &
                                     +  mv_ts(2)%sf(j, k, l, q, i) &
                                    + dt_in*rhs_mv(j, k, l, q, i))/4d0
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if (grid_geometry == 3) call s_apply_fourier_filter(q_cons_ts(2)%vf)

        if (model_eqns == 3) call s_pressure_relaxation_procedure(q_cons_ts(2)%vf)

        if (adv_n .and. alter_alpha) then
            !$acc parallel loop collapse(3) gang vector default(present)
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        nR3bar = 0d0
                        !$acc loop seq
                        do i = 1, nb
                            if(polytropic) then
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            else
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(2)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            end if
                        end do
                        q_cons_ts(2)%vf(alf_idx)%sf(j, k, l) = (4*pi*nR3bar)/(3*q_cons_ts(2)%vf(n_idx)%sf(j, k, l)**2)
                    end do
                end do
            enddo
        end if

        ! ==================================================================

        ! Stage 3 of 3 =====================================================
        call s_compute_rhs(q_cons_ts(2)%vf, q_prim_vf, rhs_vf, pb_ts(2)%sf, rhs_pb, mv_ts(2)%sf, rhs_mv, t_step)

!$acc parallel loop collapse(4) gang vector default(present)
        do i = 1, sys_size
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        q_cons_ts(1)%vf(i)%sf(j, k, l) = &
                            (q_cons_ts(1)%vf(i)%sf(j, k, l) &
                             + 2d0*q_cons_ts(2)%vf(i)%sf(j, k, l) &
                             + 2d0*dt_in*rhs_vf(i)%sf(j, k, l))/3d0
                    end do
                end do
            end do
        end do

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                pb_ts(1)%sf(j, k, l, q, i) = &
                                    (pb_ts(1)%sf(j, k, l, q, i) &
                                    + 2d0*pb_ts(2)%sf(j, k, l, q, i) &
                                    + 2d0*dt_in*rhs_pb(j, k, l, q, i))/3d0
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if(qbmm .and. (.not. polytropic)) then
!$acc parallel loop collapse(5) gang vector default(present)
            do i = 1, nb
                do l = 0, p
                    do k = 0, n
                        do j = 0, m
                            do q = 1, nnode
                                mv_ts(1)%sf(j, k, l, q, i) = &
                                    (mv_ts(1)%sf(j, k, l, q, i) &
                                    + 2d0*mv_ts(2)%sf(j, k, l, q, i) &
                                    + 2d0*dt_in*rhs_mv(j, k, l, q, i))/3d0
                            end do
                        end do
                    end do
                end do
            end do
        end if

        if (grid_geometry == 3) call s_apply_fourier_filter(q_cons_ts(1)%vf)

        if (model_eqns == 3) call s_pressure_relaxation_procedure(q_cons_ts(1)%vf)

        if (adv_n .and. alter_alpha) then
            !$acc parallel loop collapse(3) gang vector default(present)
            do l = 0, p
                do k = 0, n
                    do j = 0, m
                        nR3bar = 0d0
                        !$acc loop seq
                        do i = 1, nb
                            if(polytropic) then
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            else
                                nR3bar = nR3bar + weight(i) * (q_cons_ts(1)%vf(bub_idx%rs(i))%sf(j, k, l)) ** 3d0
                            end if
                        end do
                        q_cons_ts(1)%vf(alf_idx)%sf(j, k, l) = (4*pi*nR3bar)/(3*q_cons_ts(1)%vf(n_idx)%sf(j, k, l)**2)
                    end do
                end do
            end do
        end if

        ! Check
        ix%beg = 0; iy%beg = 0; iz%beg = 0
        ix%end = m - ix%beg; iy%end = n - iy%beg; iz%end = p - iz%beg

        call s_convert_conservative_to_primitive_variables( &
        q_cons_ts(1)%vf, &
        q_prim_vf, &
        gm_alpha_qp%vf, &
        ix, iy, iz)

        ! if (proc_rank == 0) then
            ! j = 15; k = 23; l = 0;
            ! write(20,*) t_step,(q_prim_vf(i)%sf(j, k, l),i=1,sys_size), q_adap_dt(j, k, l)
            ! write(30,*) t_step,(q_prim_vf(i)%sf(j, k, l),i=1,sys_size), q_adap_dt(j, k, l)
            ! j = 5; k = 22; l = 0;
            ! write(21,*) t_step,(q_prim_vf(i)%sf(j, k, l),i=1,sys_size), q_adap_dt(j, k, l)
            ! write(31,*) t_step,(q_prim_vf(i)%sf(j, k, l),i=1,sys_size), q_adap_dt(j, k, l)
        j = 79; k = 79; l = 0;
        write(32,*) t_step,(q_prim_vf(i)%sf(j, k, l),i=1,sys_size)
        ! end if

        call nvtxEndRange

        call cpu_time(finish)

        time = time + (finish - start)

        if (t_step >= 4) then
            time_avg = (abs(finish - start) + (t_step - 4)*time_avg)/(t_step - 3)
        else
            time_avg = 0d0
        end if

        ! ==================================================================

    end subroutine s_3rd_order_tvd_rk ! ------------------------------------

    !> 3rd order TVD RK time-stepping algorithm
        !! @param t_step Current time-step
    subroutine s_adaptive_dt_bubble(t_step, time_avg, pb, mv) ! ------------------------

        integer, intent(IN) :: t_step
        real(kind(0d0)), intent(INOUT) :: time_avg

        real(kind(0d0)), dimension(0:m, 0:n, 0:p) :: bub_adv_src
        real(kind(0d0)), dimension(0:m, 0:n, 0:p, 1:nb ) :: bub_r_src, &
                                                            bub_v_src, &
                                                            bub_p_src, &
                                                            bub_m_src
        type(scalar_field) :: divu
        real(kind(0d0)), dimension(0:m, 0:n, 0:p) :: nbub

        real(kind(0d0)), dimension(startx:, starty:, startz:, 1:, 1:), intent (INOUT) :: pb, mv

        integer :: j, k, l !< Generic loop iterator
        type(int_bounds_info) :: ix, iy, iz
        type(vector_field) :: gm_alpha_qp  !<

        integer :: id

        call s_populate_conservative_variables_buffers(q_cons_ts(1)%vf, pb, mv)

        ! Compute q_prim from q_cons
        ix%beg = 0; iy%beg = 0; iz%beg = 0
        ix%end = m - ix%beg; iy%end = n - iy%beg; iz%end = p - iz%beg

        call s_convert_conservative_to_primitive_variables( &
        q_cons_ts(1)%vf, &
        q_prim_vf, &
        gm_alpha_qp%vf, &
        ix, iy, iz)

        ! Compute bubble source
        call s_compute_bubble_source(bub_adv_src, bub_r_src, bub_v_src, bub_p_src, bub_m_src, divu, nbub, &
                    q_cons_ts(1)%vf(1:sys_size), q_prim_vf(1:sys_size), t_step, id, rhs_vf)

        ! Update
        !$acc parallel loop collapse(3) gang vector default(present)
        do l = iz%beg, iz%end
            do k = iy%beg, iy%end
                do j = ix%beg, ix%end
                    q_cons_ts(1)%vf(bub_idx%rs(1))%sf(j, k, l) = &
                                bub_r_src(j, k, l, 1)
                    q_cons_ts(1)%vf(bub_idx%vs(1))%sf(j, k, l) = &
                                bub_v_src(j, k, l, 1)
                end do
            end do
        end do

    end subroutine s_adaptive_dt_bubble ! ------------------------------

    !> Strang splitting scheme with 3rd order TVD RK time-stepping algorithm for
        !!      the flux term and 3rd order adaptive time stepping algorithm for 
        !!      the source term
        !! @param t_step Current time-step
    subroutine s_strang_splitting(t_step, time_avg) ! --------------------------------

        integer, intent(IN) :: t_step
        real(kind(0d0)), intent(INOUT) :: time_avg

        integer :: i, j, k, l !< Generic loop iterator
        real(kind(0d0)) :: start, finish

        type(int_bounds_info) :: ix, iy, iz
        type(vector_field) :: gm_alpha_qp  !<

        call cpu_time(start)

        call nvtxStartRange("Operator_splitting")

        ! Stage 1 of 3 =====================================================
        call s_3rd_order_tvd_rk(t_step, time_avg, dt/2)

        ! Stage 2 of 3 =====================================================
        call s_adaptive_dt_bubble(t_step, time_avg, pb_ts(1)%sf, mv_ts(1)%sf)

        ! Stage 3 of 3 =====================================================
        call s_3rd_order_tvd_rk(t_step, time_avg, dt/2)

        ! ! Check
        ! ix%beg = 0; iy%beg = 0; iz%beg = 0
        ! ix%end = m - ix%beg; iy%end = n - iy%beg; iz%end = p - iz%beg

        ! call s_convert_conservative_to_primitive_variables( &
        ! q_cons_ts(1)%vf, &
        ! q_prim_vf, &
        ! gm_alpha_qp%vf, &
        ! ix, iy, iz)

        ! if (n == 0) then
        !     j = 1; k = 0; l = 0;
        !     if (mod(t_step - t_step_start, t_step_save) == 0) then
        !         write(32,*) t_step,(q_prim_vf(i)%sf(j, k, l),i=1,sys_size)
        !     end if
        ! end if

        call nvtxEndRange

        call cpu_time(finish)

        time = time + (finish - start)

        if (t_step >= 4) then
            time_avg = (abs(finish - start) + (t_step - 4)*time_avg)/(t_step - 3)
        else
            time_avg = 0d0
        end if

        ! ==================================================================

    end subroutine s_strang_splitting ! ------------------------------------

    !> This subroutine saves the temporary q_prim_vf vector
        !!      into the q_prim_ts vector that is then used in p_main
        !! @param t_step current time-step
    subroutine s_time_step_cycling(t_step) ! ----------------------------

        integer, intent(IN) :: t_step

        integer :: i !< Generic loop iterator

        do i = 1, sys_size
!$acc update host(q_prim_vf(i)%sf)
        end do

        if (t_step == t_step_start) then
            do i = 1, sys_size
                q_prim_ts(3)%vf(i)%sf(:, :, :) = q_prim_vf(i)%sf(:, :, :)
            end do
        elseif (t_step == t_step_start + 1) then
            do i = 1, sys_size
                q_prim_ts(2)%vf(i)%sf(:, :, :) = q_prim_vf(i)%sf(:, :, :)
            end do
        elseif (t_step == t_step_start + 2) then
            do i = 1, sys_size
                q_prim_ts(1)%vf(i)%sf(:, :, :) = q_prim_vf(i)%sf(:, :, :)
            end do
        elseif (t_step == t_step_start + 3) then
            do i = 1, sys_size
                q_prim_ts(0)%vf(i)%sf(:, :, :) = q_prim_vf(i)%sf(:, :, :)
            end do
        else ! All other timesteps
            do i = 1, sys_size
                q_prim_ts(3)%vf(i)%sf(:, :, :) = q_prim_ts(2)%vf(i)%sf(:, :, :)
                q_prim_ts(2)%vf(i)%sf(:, :, :) = q_prim_ts(1)%vf(i)%sf(:, :, :)
                q_prim_ts(1)%vf(i)%sf(:, :, :) = q_prim_ts(0)%vf(i)%sf(:, :, :)
                q_prim_ts(0)%vf(i)%sf(:, :, :) = q_prim_vf(i)%sf(:, :, :)
            end do
        end if

    end subroutine s_time_step_cycling ! -----------------------------------

    !> Module deallocation and/or disassociation procedures
    subroutine s_finalize_time_steppers_module() ! -------------------------

        integer :: i, j !< Generic loop iterators

        ! Deallocating the cell-average conservative variables
        do i = 1, num_ts

            do j = 1, sys_size
                @:DEALLOCATE(q_cons_ts(i)%vf(j)%sf)
            end do

            @:DEALLOCATE(q_cons_ts(i)%vf)

        end do

        @:DEALLOCATE(q_cons_ts)

        ! Deallocating the cell-average primitive ts variables
        if (probe_wrt) then
            do i = 0, 3
                do j = 1, sys_size
                    @:DEALLOCATE(q_prim_ts(i)%vf(j)%sf)
                end do
                @:DEALLOCATE(q_prim_ts(i)%vf)
            end do
            @:DEALLOCATE(q_prim_ts)
        end if

        ! Deallocating the cell-average primitive variables
        do i = 1, adv_idx%end
            @:DEALLOCATE(q_prim_vf(i)%sf)
        end do

        if (hypoelasticity) then
            do i = stress_idx%beg, stress_idx%end
                @:DEALLOCATE(q_prim_vf(i)%sf)
            end do
        end if

        if (bubbles) then
            do i = bub_idx%beg, bub_idx%end
                @:DEALLOCATE(q_prim_vf(i)%sf)
            end do
        end if

        if (model_eqns == 3) then
            do i = internalEnergies_idx%beg, internalEnergies_idx%end
                @:DEALLOCATE(q_prim_vf(i)%sf)
            end do
        end if

        @:DEALLOCATE(q_prim_vf)

        ! Deallocating the cell-average RHS variables
        do i = 1, sys_size
            @:DEALLOCATE(rhs_vf(i)%sf)
        end do

        @:DEALLOCATE(rhs_vf)

        ! Writing the footer of and closing the run-time information file
        if (proc_rank == 0 .and. run_time_info) then
            call s_close_run_time_information_file()
        end if

    end subroutine s_finalize_time_steppers_module ! -----------------------

end module m_time_steppers
