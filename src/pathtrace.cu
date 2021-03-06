#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

// for material sorting
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/scan.h>

// for performance measuring
#include <fstream>
#include "common.h"

// toggle Anti-aliasing
#define AA_ON 1

// toggle first bounce cache
#define FIRST_BOUNCE_CACHE 0

// toggle sort by material
#define SORT_BY_MATERIAL 0


// For performance measuring: write results to a file
extern FILE* fp;

#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
// cache first bounce
static PathSegment * dev_first_bounces = NULL;
static ShadeableIntersection * dev_first_bounce_intersections = NULL;
// mesh loading
static Vertex* dev_vertices = NULL;



void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

    // TODO: initialize any extra device memeory you need
	cudaMalloc(&dev_first_bounces, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_first_bounce_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_first_bounce_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	// Loading meshes
	cudaMalloc(&dev_vertices, hst_scene->vertices.size() * sizeof(Vertex));
	cudaMemcpy(dev_vertices, hst_scene->vertices.data(), hst_scene->vertices.size() * sizeof(Vertex), cudaMemcpyHostToDevice);

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
    // TODO: clean up any extra device memory you created

	cudaFree(dev_vertices);
	cudaFree(dev_first_bounces);
	cudaFree(dev_first_bounce_intersections);

    checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);
		// loading meshes
		segment.is_terminated = false;

		
#if AA_ON
		// TODO: implement antialiasing by jittering the ray
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, x + y, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)(x + u01(rng)) - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)(y + u01(rng)) - (float)cam.resolution.y * 0.5f)
		);
#else
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
#endif
		

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	,Vertex * vertices
	)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?

			else if (geom.type == MESH)
			{
				t = meshIntersectionCheck(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside, vertices);
			}
			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			intersections[path_index].outside = outside;
		}
	}
}
/*
// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial (
  int iter
  , int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
	)
{
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    ShadeableIntersection intersection = shadeableIntersections[idx];
    if (intersection.t > 0.0f) { // if the intersection exists...
      // Set up the RNG
      // LOOK: this is how you use thrust's RNG! Please look at
      // makeSeededRandomEngine as well.
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
      thrust::uniform_real_distribution<float> u01(0, 1);

      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;

      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        pathSegments[idx].color *= (materialColor * material.emittance);
      }
      // Otherwise, do some pseudo-lighting computation. This is actually more
      // like what you would expect from shading in a rasterizer like OpenGL.
      // TODO: replace this! you should be able to start with basically a one-liner
      else {
        float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
        pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
        pathSegments[idx].color *= u01(rng); // apply some noise because why not
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      pathSegments[idx].color = glm::vec3(0.0f);
    }
  }
}
*/
// part1, create a basic shading function
__global__ void shadeMaterialBasic(
	int iter, 
	int num_paths,
	int depth  //need to add depth!
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		// part1 get the intersection info
		ShadeableIntersection intersection = shadeableIntersections[idx];
		// part1 get the path Segment
		PathSegment& pathSegment = pathSegments[idx];
		// part1 check if the path still need to bounce off:
		if (pathSegment.remainingBounces == 0)
			return;

		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
		  // part1 : need to add depth in this! 
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, depth);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegment.color *= (materialColor * material.emittance);

				// part1 also need to terminate the ray!
				pathSegment.remainingBounces = 0;
				pathSegment.is_terminated = true;
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				scatterRay(pathSegment,
					getPointOnRay(pathSegment.ray, intersection.t),
					intersection.surfaceNormal,
					material,
					rng,
					intersection.outside);
				pathSegment.remainingBounces--;
			}
			//if (pathSegments[idx].remainingBounces == 0) pathSegments[idx].color *= glm::vec3(0.0);
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegment.color = glm::vec3(0.0f);
			pathSegment.remainingBounces = 0;
		}
	}
}
//shading function end

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

// Used for path compaction
struct is_live
{
	__host__ __device__
		bool operator()(const PathSegment &x)
	{
		return (x.remainingBounces) > 0;
	}
};


// Used for Sorting by MaterialId
// data structure for sorting
typedef thrust::tuple<PathSegment, ShadeableIntersection> PathMate;
struct mateCompare
{
	__host__ __device__ 
		bool operator() (const PathMate& x, const PathMate& y)
	{
		return x.get<1>().materialId < y.get<1>().materialId;
	}
};

// function performing material Sorting
void sortByMaterial(int num_path, PathSegment* dev_paths, ShadeableIntersection* dev_intersections)
{
	thrust::device_ptr<PathSegment> pathPtr(dev_paths);
	thrust::device_ptr<ShadeableIntersection> intersectionPtr(dev_intersections);

	typedef thrust::tuple<thrust::device_ptr<PathSegment>, thrust::device_ptr<ShadeableIntersection>> PathMatePtr;
	typedef thrust::zip_iterator<PathMatePtr> PathMateIterator;

	PathMateIterator pathMate_begin = thrust::make_zip_iterator(thrust::make_tuple(pathPtr, intersectionPtr));
	PathMateIterator pathMate_end = pathMate_begin + num_path;
	thrust::sort(pathMate_begin, pathMate_end, mateCompare());
}
/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing
	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;
	int active_paths = num_paths;
	bool outside = true;
	// For performance measuring	
	Common::PerformanceTimer timer;
	timer.startGpuTimer();

    // For first bounce cache, we cache the result from first bounce
	// If anti-aliasing is on, this cannot work
#if FIRST_BOUNCE_CACHE && !AA_ON
	if (iter == 1)
	{
		generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
		checkCUDAError("generate camera ray");
		cudaMemcpy(dev_first_bounces, dev_paths, num_paths * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
		checkCUDAError("Memcpy dev_paths to dev_first_bounces");
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
		dim3 numblocksPathSegmentTracing = (active_paths + blockSize1d - 1) / blockSize1d;
		// tracing
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, active_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			, dev_vertices
			);
		checkCUDAError("trace one bounce");
		// After tracing first bounce, store the value into dev_first_bounces
		cudaMemcpy(dev_first_bounce_intersections, dev_intersections, num_paths * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		checkCUDAError("Memcpy dev_intersections to dev_cache_intersections");
}
#endif
	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	bool firstBounce = true;
	//for (int i = 0; i < traceDepth && !iterationComplete; i++) {
		//for (int i = 0; i < 1; i++) {
	while (!iterationComplete) {
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
		dim3 numblocksPathSegmentTracing = (active_paths + blockSize1d - 1) / blockSize1d;
		
		// check if this is first bounce
		if (firstBounce)
		{
			firstBounce = false;
#if FIRST_BOUNCE_CACHE && !AA_ON
			// if first bounce is cached, copy data back
			cudaMemcpy(dev_paths, dev_first_bounces, num_paths * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
			cudaMemcpy(dev_intersections, dev_first_bounce_intersections, num_paths * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
#else
			generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
			checkCUDAError("generate camera ray");
			// clean shading chunks
			//cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

			// tracing
			dim3 numblocksPathSegmentTracingFirstBounce = (num_paths + blockSize1d - 1) / blockSize1d;
			computeIntersections << <numblocksPathSegmentTracingFirstBounce, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				, dev_vertices
				);
			checkCUDAError("trace one bounce");
#endif
		}
		else
		{
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				, dev_vertices
				);
			checkCUDAError("trace one bounce");
		}
		cudaDeviceSynchronize();
		depth++;
		if (depth == traceDepth) {
			iterationComplete = true;
			continue;
		}

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	  // evaluating the BSDF.
	  // Start off with just a big kernel that handles all the different
	  // materials you have in the scenefile.
	  // TODO: compare between directly shading the path segments and shading
	  // path segments that have been reshuffled to be contiguous in memory.

#if SORT_BY_MATERIAL
		sortByMaterial(num_paths, dev_paths, dev_intersections);
#endif
		shadeMaterialBasic << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			active_paths,
			depth,
			dev_intersections,
			dev_paths,
			dev_materials
			);
        // stream compaction on paths
		PathSegment* partMiddle = thrust::partition(thrust::device, dev_paths, dev_paths + active_paths, is_live());
		active_paths = partMiddle - dev_paths;
		iterationComplete = active_paths <= 0;
	}
	// For performance measuring
	timer.endGpuTimer();
	fprintf(fp, "%lf\n", timer.getGpuElapsedTimeForPreviousOperation());
	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
