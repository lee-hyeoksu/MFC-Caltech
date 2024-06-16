#!/usr/bin/env bash

<%namespace name="helpers" file="helpers.mako"/>

% if engine == 'batch':
#SBATCH --nodes=${nodes}
#SBATCH --ntasks-per-node=${tasks_per_node}
#SBATCH --cpus-per-task=1
#SBATCH --job-name="${name}"
#SBATCH --time=${walltime}
% if partition:
#SBATCH --partition=${partition}
% endif
% if account:
#SBATCH --account="${account}"
% endif
#SBATCH --output="${name}.out"
#SBATCH --error="${name}.err"
#SBATCH --export=ALL
% if email:
#SBATCH --mail-user=${email}
#SBATCH --mail-type="BEGIN, END, FAIL"
% endif
% endif

${helpers.template_prologue()}

# ok ":) Loading modules:\n"
# cd "${MFC_ROOTDIR}"
# . ./mfc.sh load -c b -m ${'g' if gpu else 'c'}
# cd - > /dev/null
# echo

% for target in targets:
    ${helpers.run_prologue(target)}

    % if not mpi:
        (set -x; ${' '.join([f"'{x}'" for x in profiler ])} "${target.get_install_binpath(case)}")
    % else:
        (set -x; ${' '.join([f"'{x}'" for x in profiler ])}             \
            mpirun -np ${nodes*tasks_per_node}                 \
                   ${' '.join([f"'{x}'" for x in ARG('--') ])} \
                   "${target.get_install_binpath(case)}")
    % endif

    ${helpers.run_epilogue(target)}

    echo
% endfor

${helpers.template_epilogue()}
