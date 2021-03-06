/*  Copyright (c) 2011-2019 INGV, EDF, UniCT, JHU

    Istituto Nazionale di Geofisica e Vulcanologia, Sezione di Catania, Italy
    Électricité de France, Paris, France
    Università di Catania, Catania, Italy
    Johns Hopkins University, Baltimore (MD), USA

    This file is part of GPUSPH. Project founders:
        Alexis Hérault, Giuseppe Bilotta, Robert A. Dalrymple,
        Eugenio Rustico, Ciro Del Negro
    For a full list of authors and project partners, consult the logs
    and the project website <https://www.gpusph.org>

    GPUSPH is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    GPUSPH is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with GPUSPH.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdio.h>
#include <stdexcept>

#include "textures.cuh"

#include "engine_forces.h"
#include "engine_visc.h"
#include "engine_filter.h"
#include "simflags.h"
#include "multi_gpu_defines.h"
#include "Writer.h"

#include "utils.h"
#include "cuda_call.h"

#include "define_buffers.h"

#include "post_process_kernel.cu"

/// Post-processing engines

// As with the viscengine and filter engines, we need a helper struct for the partial
// specialization of process

struct CUDAPostProcessEngineHelperDefaults
{
	static flag_t get_written_buffers(flag_t options)
	{ return NO_FLAGS; }

	static flag_t get_updated_buffers(flag_t options)
	{ return NO_FLAGS; }

	static void
	setconstants(const SimParams *simparams, const PhysParams *physparams,
		idx_t const& allocatedParticles)
	{}

	static void
	hostAllocate(const GlobalData * const gdata)
	{}

	static void
	hostProcess(const GlobalData * const gdata)
	{}

	static void
	write(WriterMap writers, double t)
	{}

};

template<PostProcessType filtertype, KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
struct CUDAPostProcessEngineHelper : public CUDAPostProcessEngineHelperDefaults
{
	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata);
};

template<KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
struct CUDAPostProcessEngineHelper<VORTICITY, kerneltype, boundarytype, simflags>
: public CUDAPostProcessEngineHelperDefaults
{
	static flag_t get_written_buffers(flag_t)
	{ return BUFFER_VORTICITY; }

	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		// thread per particle
		uint numThreads = BLOCK_SIZE_CALCVORT;
		uint numBlocks = div_up(particleRangeEnd, numThreads);

		const float4 *pos = bufread.getData<BUFFER_POS>();
		const float4 *vel = bufread.getData<BUFFER_VEL>();
		const particleinfo *info = bufread.getData<BUFFER_INFO>();
		const hashKey *particleHash = bufread.getData<BUFFER_HASH>();
		const uint *cellStart = bufread.getData<BUFFER_CELLSTART>();
		const neibdata *neibsList = bufread.getData<BUFFER_NEIBSLIST>();

		float3 *vort = bufwrite.getData<BUFFER_VORTICITY>();

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaBindTexture(0, posTex, pos, numParticles*sizeof(float4)));
		#endif
		CUDA_SAFE_CALL(cudaBindTexture(0, velTex, vel, numParticles*sizeof(float4)));
		CUDA_SAFE_CALL(cudaBindTexture(0, infoTex, info, numParticles*sizeof(particleinfo)));

		cupostprocess::calcVortDevice<kerneltype><<< numBlocks, numThreads >>>
			(	pos,
				vort,
				particleHash,
				cellStart,
				neibsList,
				particleRangeEnd,
				gdata->problem->simparams()->slength,
				gdata->problem->simparams()->influenceRadius);

		// check if kernel invocation generated an error
		KERNEL_CHECK_ERROR;

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaUnbindTexture(posTex));
		#endif
		CUDA_SAFE_CALL(cudaUnbindTexture(velTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(infoTex));
	}
};

template<KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
struct CUDAPostProcessEngineHelper<TESTPOINTS, kerneltype, boundarytype, simflags>
: public CUDAPostProcessEngineHelperDefaults
{
	// buffers updated in-place
	static flag_t get_updated_buffers(flag_t)
	{ return BUFFER_VEL | BUFFER_TKE | BUFFER_EPSILON; }

	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		// thread per particle
		uint numThreads = BLOCK_SIZE_CALCTEST;
		uint numBlocks = div_up(particleRangeEnd, numThreads);

		const float4 *pos = bufread.getData<BUFFER_POS>();
		const particleinfo *info = bufread.getData<BUFFER_INFO>();
		const hashKey *particleHash = bufread.getData<BUFFER_HASH>();
		const uint *cellStart = bufread.getData<BUFFER_CELLSTART>();
		const neibdata *neibsList = bufread.getData<BUFFER_NEIBSLIST>();

		/* in-place update! */
		float4 *newVel = bufwrite.getData<BUFFER_VEL>();
		float *newTke = bufwrite.getData<BUFFER_TKE>();
		float *newEpsilon = bufwrite.getData<BUFFER_EPSILON>();

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaBindTexture(0, posTex, pos, numParticles*sizeof(float4)));
		#endif
		CUDA_SAFE_CALL(cudaBindTexture(0, velTex, newVel, numParticles*sizeof(float4)));
		if (newTke)
			CUDA_SAFE_CALL(cudaBindTexture(0, keps_kTex, newTke, numParticles*sizeof(float)));
		if (newEpsilon)
			CUDA_SAFE_CALL(cudaBindTexture(0, keps_eTex, newEpsilon, numParticles*sizeof(float)));
		CUDA_SAFE_CALL(cudaBindTexture(0, infoTex, info, numParticles*sizeof(particleinfo)));

		// execute the kernel
		cupostprocess::calcTestpointsVelocityDevice<kerneltype, boundarytype><<< numBlocks, numThreads >>>
			(	pos,
				newVel,
				newTke,
				newEpsilon,
				particleHash,
				cellStart,
				neibsList,
				particleRangeEnd,
				gdata->problem->simparams()->slength,
				gdata->problem->simparams()->influenceRadius);

		// check if kernel invocation generated an error
		KERNEL_CHECK_ERROR;

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaUnbindTexture(posTex));
		#endif
		CUDA_SAFE_CALL(cudaUnbindTexture(velTex));
		if (newTke)
			CUDA_SAFE_CALL(cudaUnbindTexture(keps_kTex));
		if (newEpsilon)
			CUDA_SAFE_CALL(cudaUnbindTexture(keps_eTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(infoTex));
	}
};

template<KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
struct CUDAPostProcessEngineHelper<SURFACE_DETECTION, kerneltype, boundarytype, simflags>
: public CUDAPostProcessEngineHelperDefaults
{
	// buffers updated in-place
	static flag_t get_updated_buffers(flag_t)
	{ return BUFFER_INFO; }

	// pass BUFFER_NORMALS option to the SURFACE_DETECTION filter
	// to save normals too
	static flag_t get_written_buffers(flag_t options)
	{ return (options & BUFFER_NORMALS); }

	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		// thread per particle
		uint numThreads = BLOCK_SIZE_CALCTEST;
		uint numBlocks = div_up(particleRangeEnd, numThreads);

		const float4 *pos = bufread.getData<BUFFER_POS>();
		const float4 *vel = bufread.getData<BUFFER_VEL>();
		const particleinfo *info = bufread.getData<BUFFER_INFO>();
		const hashKey *particleHash = bufread.getData<BUFFER_HASH>();
		const uint *cellStart = bufread.getData<BUFFER_CELLSTART>();
		const neibdata *neibsList = bufread.getData<BUFFER_NEIBSLIST>();

		/* in-place update! */
		particleinfo *newInfo = bufwrite.getData<BUFFER_INFO,
			BufferList::AccessSafety::MULTISTATE_SAFE>();

		float4 *normals = bufwrite.getData<BUFFER_NORMALS>();

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaBindTexture(0, posTex, pos, numParticles*sizeof(float4)));
		#endif
		CUDA_SAFE_CALL(cudaBindTexture(0, velTex, vel, numParticles*sizeof(float4)));
		CUDA_SAFE_CALL(cudaBindTexture(0, infoTex, info, numParticles*sizeof(particleinfo)));

		// execute the kernel
		if (options & BUFFER_NORMALS) {
			cupostprocess::calcSurfaceparticleDevice<kerneltype, boundarytype, simflags, true><<< numBlocks, numThreads >>>
				(	pos,
					normals,
					newInfo,
					particleHash,
					cellStart,
					neibsList,
					particleRangeEnd,
					gdata->problem->simparams()->slength,
					gdata->problem->simparams()->influenceRadius);
		} else {
			cupostprocess::calcSurfaceparticleDevice<kerneltype, boundarytype, simflags, false><<< numBlocks, numThreads >>>
				(	pos,
					normals,
					newInfo,
					particleHash,
					cellStart,
					neibsList,
					particleRangeEnd,
					gdata->problem->simparams()->slength,
					gdata->problem->simparams()->influenceRadius);
		}

		// check if kernel invocation generated an error
		KERNEL_CHECK_ERROR;

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaUnbindTexture(posTex));
		#endif
		CUDA_SAFE_CALL(cudaUnbindTexture(velTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(infoTex));
	}
};

// Interface detection for multi-phase flows
template<KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
struct CUDAPostProcessEngineHelper<INTERFACE_DETECTION, kerneltype, boundarytype, simflags>
: public CUDAPostProcessEngineHelperDefaults
{
	// buffers updated in-place
	static flag_t get_updated_buffers(flag_t)
	{ return BUFFER_INFO; }

	// pass BUFFER_NORMALS option to the INTERFACE_DETECTION filter
	// to save normals too
	static flag_t get_written_buffers(flag_t options)
	{ return (options & BUFFER_NORMALS); }

	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		// thread per particle
		uint numThreads = BLOCK_SIZE_CALCTEST;
		uint numBlocks = div_up(particleRangeEnd, numThreads);

		const float4 *pos = bufread.getData<BUFFER_POS>();
		const float4 *vel = bufread.getData<BUFFER_VEL>();
		const particleinfo *info = bufread.getData<BUFFER_INFO>();
		const hashKey *particleHash = bufread.getData<BUFFER_HASH>();
		const uint *cellStart = bufread.getData<BUFFER_CELLSTART>();
		const neibdata *neibsList = bufread.getData<BUFFER_NEIBSLIST>();

		/* in-place update! */
		particleinfo *newInfo = bufwrite.getData<BUFFER_INFO,
			BufferList::AccessSafety::MULTISTATE_SAFE>();

		float4 *normals = bufwrite.getData<BUFFER_NORMALS>();

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaBindTexture(0, posTex, pos, numParticles*sizeof(float4)));
		#endif
		CUDA_SAFE_CALL(cudaBindTexture(0, velTex, vel, numParticles*sizeof(float4)));
		CUDA_SAFE_CALL(cudaBindTexture(0, infoTex, info, numParticles*sizeof(particleinfo)));

		// execute the kernel
		if (options & BUFFER_NORMALS) {
			cupostprocess::calcInterfaceparticleDevice<kerneltype, boundarytype, simflags, true><<< numBlocks, numThreads >>>
				(	pos,
					normals,
					newInfo,
					particleHash,
					cellStart,
					neibsList,
					particleRangeEnd,
					gdata->problem->m_deltap,
					gdata->problem->simparams()->slength,
					gdata->problem->simparams()->influenceRadius);
		} else {
			cupostprocess::calcInterfaceparticleDevice<kerneltype, boundarytype, simflags, false><<< numBlocks, numThreads >>>
				(	pos,
					normals,
					newInfo,
					particleHash,
					cellStart,
					neibsList,
					particleRangeEnd,
					gdata->problem->m_deltap,
					gdata->problem->simparams()->slength,
					gdata->problem->simparams()->influenceRadius);
		}

		// check if kernel invocation generated an error
		KERNEL_CHECK_ERROR;

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaUnbindTexture(posTex));
		#endif
		CUDA_SAFE_CALL(cudaUnbindTexture(velTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(infoTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(gamTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(boundTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(vertTex));
	}
};

// Interface detection for multi-phase flows
// Specialization for SA_BOUNDARY
template<KernelType kerneltype, flag_t simflags>
struct CUDAPostProcessEngineHelper<INTERFACE_DETECTION, kerneltype, SA_BOUNDARY, simflags>
: public CUDAPostProcessEngineHelperDefaults
{
	// buffers updated in-place
	static flag_t get_updated_buffers(flag_t)
	{ return BUFFER_INFO; }

	// pass BUFFER_NORMALS option to the INTERFACE_DETECTION filter
	// to save normals too
	static flag_t get_written_buffers(flag_t options)
	{ return (options & BUFFER_NORMALS); }

	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		// thread per particle
		uint numThreads = BLOCK_SIZE_CALCTEST;
		uint numBlocks = div_up(particleRangeEnd, numThreads);

		const float4 *pos = bufread.getData<BUFFER_POS>();
		const float4 *gGam = bufread.getData<BUFFER_GRADGAMMA>();
		const float4 *vel = bufread.getData<BUFFER_VEL>();
		const particleinfo *info = bufread.getData<BUFFER_INFO>();
		const hashKey *particleHash = bufread.getData<BUFFER_HASH>();
		const uint *cellStart = bufread.getData<BUFFER_CELLSTART>();
		const neibdata *neibsList = bufread.getData<BUFFER_NEIBSLIST>();
		const float4 *boundElement = bufread.getData<BUFFER_BOUNDELEMENTS>();	
		const float2 * const *vertPos = bufread.getRawPtr<BUFFER_VERTPOS>();

		CUDA_SAFE_CALL(cudaBindTexture(0, boundTex, boundElement, numParticles*sizeof(float4)));

		/* in-place update! */
		particleinfo *newInfo = bufwrite.getData<BUFFER_INFO,
			BufferList::AccessSafety::MULTISTATE_SAFE>();

		float4 *normals = bufwrite.getData<BUFFER_NORMALS>();

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaBindTexture(0, posTex, pos, numParticles*sizeof(float4)));
		#endif
		CUDA_SAFE_CALL(cudaBindTexture(0, velTex, vel, numParticles*sizeof(float4)));
		CUDA_SAFE_CALL(cudaBindTexture(0, infoTex, info, numParticles*sizeof(particleinfo)));
		CUDA_SAFE_CALL(cudaBindTexture(0, gamTex, gGam, numParticles*sizeof(float4)));

		// execute the kernel
		if (options & BUFFER_NORMALS) {
			cupostprocess::calcInterfaceparticleDevice<kerneltype, SA_BOUNDARY, simflags, true><<< numBlocks, numThreads >>>
				(	pos,
					normals,
					newInfo,
					vertPos[0],
					vertPos[1],
					vertPos[2],
					particleHash,
					cellStart,
					neibsList,
					particleRangeEnd,
					gdata->problem->m_deltap,
					gdata->problem->simparams()->slength,
					gdata->problem->simparams()->influenceRadius);
		} else {
			cupostprocess::calcInterfaceparticleDevice<kerneltype, SA_BOUNDARY, simflags, false><<< numBlocks, numThreads >>>
				(	pos,
					normals,
					newInfo,
					vertPos[0],
					vertPos[1],
					vertPos[2],
					particleHash,
					cellStart,
					neibsList,
					particleRangeEnd,
					gdata->problem->m_deltap,
					gdata->problem->simparams()->slength,
					gdata->problem->simparams()->influenceRadius);
		}

		// check if kernel invocation generated an error
		KERNEL_CHECK_ERROR;

		#if !PREFER_L1
		CUDA_SAFE_CALL(cudaUnbindTexture(posTex));
		#endif
		CUDA_SAFE_CALL(cudaUnbindTexture(velTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(infoTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(gamTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(boundTex));
		CUDA_SAFE_CALL(cudaUnbindTexture(vertTex));
	}
};

template<KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
struct CUDAPostProcessEngineHelper<FLUX_COMPUTATION, kerneltype, boundarytype, simflags>
: public CUDAPostProcessEngineHelperDefaults
{
	static float **h_IOflux;

	// buffers updated in-place
	static flag_t get_written_buffers(flag_t)
	{ return NO_FLAGS; }

	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		// thread per particle
		uint numThreads = BLOCK_SIZE_CALCTEST;
		uint numBlocks = div_up(particleRangeEnd, numThreads);

		const particleinfo *info = bufread.getData<BUFFER_INFO>();
		const float4 *eulerVel = bufread.getData<BUFFER_EULERVEL>();
		const float4 *boundElement = bufread.getData<BUFFER_BOUNDELEMENTS>();

		float *d_IOflux;

		const uint numOpenBoundaries = gdata->problem->simparams()->numOpenBoundaries;

		CUDA_SAFE_CALL(cudaMalloc(&d_IOflux, numOpenBoundaries*sizeof(float)));

		//execute kernel
		cupostprocess::fluxComputationDevice<<<numBlocks, numThreads>>>
			(	info,
				eulerVel,
				boundElement,
				d_IOflux,
				numParticles);

		CUDA_SAFE_CALL(cudaMemcpy((void *) h_IOflux[deviceIndex], (void *) d_IOflux, numOpenBoundaries*sizeof(float), cudaMemcpyDeviceToHost));

		// check if kernel invocation generated an error
		KERNEL_CHECK_ERROR;
	}

	static void
	hostAllocate(const GlobalData * const gdata)
	{
		const uint numDev = gdata->devices > 1 ? MAX_DEVICES_PER_NODE : 1;
		const uint numOpenBoundaries = gdata->problem->simparams()->numOpenBoundaries;
		if (numOpenBoundaries > 0) {
			h_IOflux = new float* [numDev];
			for (uint i = 0; i < numDev; i++)
				h_IOflux[i] = new float [numOpenBoundaries];
		}
	}

	static void
	hostProcess(const GlobalData * const gdata)
	{
		const uint numOpenBoundaries = gdata->problem->simparams()->numOpenBoundaries;

		// for multiple devices sum over all of them and write the result in the array for the first device
		if (gdata->devices > 1) {
			for (uint ob = 0; ob < numOpenBoundaries; ob++) {
				for (uint d = 1; d < gdata->devices; d++)
					h_IOflux[0][ob] += h_IOflux[d][ob];
			} // Iterate on boundaries on which we compute fluxes
		}

		// if running multinode, also reduce across nodes
		if (gdata->mpi_nodes > 1)
			// to minimize the overhead, we reduce the whole arrays of forces and torques in one command
			gdata->networkManager->networkFloatReduction(h_IOflux[0], numOpenBoundaries, SUM_REDUCTION);
	}

	static void
	write(WriterMap writers, double t)
	{
		Writer::WriteFlux(writers, t, h_IOflux[0]);
	}
};

template<KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
float** CUDAPostProcessEngineHelper<FLUX_COMPUTATION, kerneltype, boundarytype, simflags>::h_IOflux;

template<KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
struct CUDAPostProcessEngineHelper<CALC_PRIVATE, kerneltype, boundarytype, simflags>
: public CUDAPostProcessEngineHelperDefaults
{
	// pass BUFFER_PRIVATE2 and/or BUFFER_PRIVATE4 to the CALC_PRIVATE filter
	// to make these buffers available to calcPrivate (and saved)
	static flag_t get_written_buffers(flag_t options)
	{ return BUFFER_PRIVATE | (options & (BUFFER_PRIVATE2 | BUFFER_PRIVATE4)) ; }

	static void process(
				flag_t					options,
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		gdata->problem->calcPrivate(options, bufread, bufwrite,
			numParticles, particleRangeEnd,
			deviceIndex, gdata);

		// check if kernel invocation generated an error
		KERNEL_CHECK_ERROR;
	}
};

/// The actual CUDAPostProcessEngine class delegates to the helpers
template<PostProcessType pptype, KernelType kerneltype, BoundaryType boundarytype, flag_t simflags>
class CUDAPostProcessEngine : public AbstractPostProcessEngine
{
	typedef CUDAPostProcessEngineHelper<pptype, kerneltype, boundarytype, simflags> Helper;

public:
	CUDAPostProcessEngine(flag_t options=NO_FLAGS) :
		AbstractPostProcessEngine(options)
	{}

	void setconstants(const SimParams *simparams, const PhysParams *physparams,
		idx_t const& allocatedParticles) const
	{
		Helper::setconstants(simparams, physparams, allocatedParticles);
	}

	void getconstants() {} // TODO

	flag_t get_written_buffers() const
	{ return Helper::get_written_buffers(m_options); }

	flag_t get_updated_buffers() const
	{ return Helper::get_updated_buffers(m_options); }

	void process(
		BufferList const& bufread,
		BufferList&		bufwrite,
				uint					numParticles,
				uint					particleRangeEnd,
				uint					deviceIndex,
		const	GlobalData	* const		gdata)
	{
		Helper::process
			(	m_options,
				bufread,
				bufwrite,
				numParticles,
				particleRangeEnd,
				deviceIndex,
				gdata);
	}

	void hostAllocate(const GlobalData * const gdata)
	{
		Helper::hostAllocate(gdata);
	}

	void hostProcess(const GlobalData * const gdata)
	{
		Helper::hostProcess(gdata);
	}

	void write(WriterMap writers, double t)
	{
		Helper::write(writers, t);
	}
};


#if 0
/// TODO FIXME make this into a proper post-processing filter

/* Reductions */
void set_reduction_params(void* buffer, size_t blocks,
		size_t blocksize_max, size_t shmem_max)
{
	reduce_blocks = blocks;
	// in the second step of a reduction, a single block is launched, whose size
	// should be the smallest power of two that covers the number of blocks used
	// in the previous reduction run
	reduce_bs2 = 32;
	while (reduce_bs2 < blocks)
		reduce_bs2<<=1;

	reduce_blocksize_max = blocksize_max;
	reduce_shmem_max = shmem_max;
	reduce_buffer = buffer;
}

void unset_reduction_params()
{
	CUDA_SAFE_CALL(cudaFree(reduce_buffer));
	reduce_buffer = NULL;
}

// Compute system energy
void calc_energy(
		float4			*output,
	const	float4		*pos,
	const	float4		*vel,
	const	particleinfo	*pinfo,
	const	hashKey		*particleHash,
		uint			numParticles,
		uint			numFluids)
{
	// shmem needed by a single thread
	size_t shmem_thread = numFluids*sizeof(float4)*2;
	size_t blocksize_max = reduce_shmem_max/shmem_thread;
	if (blocksize_max > reduce_blocksize_max)
		blocksize_max = reduce_blocksize_max;

	size_t blocksize = 32;
	while (blocksize*2 < blocksize_max)
		blocksize<<=1;

	cupostprocess::calcEnergiesDevice<<<reduce_blocks, blocksize, blocksize*shmem_thread>>>(
			pos, vel, pinfo, particleHash, numParticles, numFluids, (float4*)reduce_buffer);
	KERNEL_CHECK_ERROR;

	cupostprocess::calcEnergies2Device<<<1, reduce_bs2, reduce_bs2*shmem_thread>>>(
			(float4*)reduce_buffer, reduce_blocks, numFluids);
	KERNEL_CHECK_ERROR;
	CUDA_SAFE_CALL(cudaMemcpy(output, reduce_buffer, numFluids*sizeof(float4), cudaMemcpyDeviceToHost));
}
#endif

