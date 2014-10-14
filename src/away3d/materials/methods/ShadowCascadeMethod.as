package away3d.materials.methods
{
    import away3d.arcane;
    import away3d.entities.DirectionalLight;
	import away3d.core.pool.RenderableBase;
	import away3d.entities.Camera3D;
    import away3d.events.ShadingMethodEvent;
    import away3d.managers.Stage3DProxy;
    import away3d.materials.compilation.MethodVO;
    import away3d.materials.compilation.ShaderObjectBase;
    import away3d.materials.compilation.ShaderRegisterCache;
    import away3d.materials.compilation.ShaderRegisterData;
    import away3d.materials.compilation.ShaderRegisterElement;
    import away3d.materials.shadowmappers.CascadeShadowMapper;
    import away3d.textures.Texture2DBase;

    import flash.events.*;

	use namespace arcane;

	/**
	 * CascadeShadowMapMethod is a shadow map method to apply cascade shadow mapping on materials.
	 * Must be used with a DirectionalLight with a CascadeShadowMapper assigned to its shadowMapper property.
	 *
	 * @see away3d.materials.shadowmappers.CascadeShadowMapper
	 */
	public class ShadowCascadeMethod extends ShadowMapMethodBase
	{
		private var _baseMethod:ShadowMethodBase;
		private var _cascadeShadowMapper:CascadeShadowMapper;
		private var _depthMapCoordVaryings:Vector.<ShaderRegisterElement>;
		private var _cascadeProjections:Vector.<ShaderRegisterElement>;
		
		/**
		 * Creates a new CascadeShadowMapMethod object.
		 *
		 * @param shadowMethodBase The shadow map sampling method used to sample individual cascades (fe: HardShadowMapMethod, SoftShadowMapMethod)
		 */
		public function ShadowCascadeMethod(shadowMethodBase:ShadowMethodBase)
		{
			super(shadowMethodBase.castingLight);
			_baseMethod = shadowMethodBase;
			if (!(_castingLight is DirectionalLight))
				throw new Error("CascadeShadowMapMethod is only compatible with DirectionalLight");
			_cascadeShadowMapper = _castingLight.shadowMapper as CascadeShadowMapper;
			
			if (!_cascadeShadowMapper)
				throw new Error("CascadeShadowMapMethod requires a light that has a CascadeShadowMapper instance assigned to shadowMapper.");
			
			_cascadeShadowMapper.addEventListener(Event.CHANGE, onCascadeChange, false, 0, true);
			_baseMethod.addEventListener(ShadingMethodEvent.SHADER_INVALIDATED, onShaderInvalidated, false, 0, true);
		}

		/**
		 * The shadow map sampling method used to sample individual cascades. These are typically those used in conjunction
		 * with a DirectionalShadowMapper.
		 *
		 * @see ShadowHardMethod
		 * @see ShadowSoftMethod
		 */
		public function get baseMethod():ShadowMethodBase
		{
			return _baseMethod;
		}
		
		public function set baseMethod(value:ShadowMethodBase):void
		{
			if (_baseMethod == value)
				return;
			_baseMethod.removeEventListener(ShadingMethodEvent.SHADER_INVALIDATED, onShaderInvalidated);
			_baseMethod = value;
			_baseMethod.addEventListener(ShadingMethodEvent.SHADER_INVALIDATED, onShaderInvalidated, false, 0, true);
			invalidateShaderProgram();
		}

		/**
		 * @inheritDoc
		 */
        override arcane function initVO(shaderObject:ShaderObjectBase, methodVO:MethodVO):void
		{
			var tempVO:MethodVO = new MethodVO(_baseMethod);
			_baseMethod.initVO(shaderObject,tempVO);
			methodVO.needsGlobalVertexPos = true;
			methodVO.needsProjection = true;
		}

		/**
		 * @inheritDoc
		 */
        override arcane function initConstants(shaderObject:ShaderObjectBase, methodVO:MethodVO):void
		{
			var fragmentData:Vector.<Number> = shaderObject.fragmentConstantData;
			var vertexData:Vector.<Number> = shaderObject.vertexConstantData;
			var index:int = methodVO.fragmentConstantsIndex;
			fragmentData[index] = 1.0;
			fragmentData[index + 1] = 1/255.0;
			fragmentData[index + 2] = 1/65025.0;
			fragmentData[index + 3] = 1/16581375.0;
			
			fragmentData[index + 6] = .5;
			fragmentData[index + 7] = -.5;
			
			index = methodVO.vertexConstantsIndex;
			vertexData[index] = .5;
			vertexData[index + 1] = -.5;
			vertexData[index + 2] = 0;
		}

		/**
		 * @inheritDoc
		 */
		arcane override function cleanCompilationData():void
		{
			super.cleanCompilationData();
			_cascadeProjections = null;
			_depthMapCoordVaryings = null;
		}

		/**
		 * @inheritDoc
		 */
		override arcane function getVertexCode(shaderObject:ShaderObjectBase, methodVO:MethodVO, registerCache:ShaderRegisterCache, sharedRegisters:ShaderRegisterData):String
		{
			var code:String = "";
			var dataReg:ShaderRegisterElement = registerCache.getFreeVertexConstant();
			
			initProjectionsRegs(registerCache);
            methodVO.vertexConstantsIndex = dataReg.index*4;
			
			var temp:ShaderRegisterElement = registerCache.getFreeVertexVectorTemp();
			
			for (var i:int = 0; i < _cascadeShadowMapper.numCascades; ++i) {
				code += "m44 " + temp + ", " + sharedRegisters.globalPositionVertex + ", " + _cascadeProjections[i] + "\n" +
					"add " + _depthMapCoordVaryings[i] + ", " + temp + ", " + dataReg + ".zzwz\n";
			}
			
			return code;
		}

		/**
		 * Creates the registers for the cascades' projection coordinates.
		 */
		private function initProjectionsRegs(regCache:ShaderRegisterCache):void
		{
			_cascadeProjections = new Vector.<ShaderRegisterElement>(_cascadeShadowMapper.numCascades);
			_depthMapCoordVaryings = new Vector.<ShaderRegisterElement>(_cascadeShadowMapper.numCascades);
			
			for (var i:int = 0; i < _cascadeShadowMapper.numCascades; ++i) {
				_depthMapCoordVaryings[i] = regCache.getFreeVarying();
				_cascadeProjections[i] = regCache.getFreeVertexConstant();
				regCache.getFreeVertexConstant();
				regCache.getFreeVertexConstant();
				regCache.getFreeVertexConstant();
			}
		}

		/**
		 * @inheritDoc
		 */
        arcane override function getFragmentCode(shaderObject:ShaderObjectBase, methodVO:MethodVO, targetReg:ShaderRegisterElement, registerCache:ShaderRegisterCache, sharedRegisters:ShaderRegisterData):String
		{
			var numCascades:int = _cascadeShadowMapper.numCascades;
			var depthMapRegister:ShaderRegisterElement = registerCache.getFreeTextureReg();
			var decReg:ShaderRegisterElement = registerCache.getFreeFragmentConstant();
			var dataReg:ShaderRegisterElement = registerCache.getFreeFragmentConstant();
			var planeDistanceReg:ShaderRegisterElement = registerCache.getFreeFragmentConstant();
			var planeDistances:Vector.<String> = new <String>[ planeDistanceReg + ".x", planeDistanceReg + ".y", planeDistanceReg + ".z", planeDistanceReg + ".w" ];
			var code:String;
			
			methodVO.fragmentConstantsIndex = decReg.index*4;
			methodVO.texturesIndex = depthMapRegister.index;
			
			var inQuad:ShaderRegisterElement = registerCache.getFreeFragmentVectorTemp();
			registerCache.addFragmentTempUsages(inQuad, 1);
			var uvCoord:ShaderRegisterElement = registerCache.getFreeFragmentVectorTemp();
			registerCache.addFragmentTempUsages(uvCoord, 1);
			
			// assume lowest partition is selected, will be overwritten later otherwise
			code = "mov " + uvCoord + ", " + _depthMapCoordVaryings[numCascades - 1] + "\n";
			
			for (var i:int = numCascades - 2; i >= 0; --i) {
				var uvProjection:ShaderRegisterElement = _depthMapCoordVaryings[i];
				
				// calculate if in texturemap (result == 0 or 1, only 1 for a single partition)
				code += "slt " + inQuad + ".z, " + sharedRegisters.projectionFragment + ".z, " + planeDistances[i] + "\n"; // z = x > minX, w = y > minY
				
				var temp:ShaderRegisterElement = registerCache.getFreeFragmentVectorTemp();
				
				// linearly interpolate between old and new uv coords using predicate value == conditional toggle to new value if predicate == 1 (true)
				code += "sub " + temp + ", " + uvProjection + ", " + uvCoord + "\n" +
					"mul " + temp + ", " + temp + ", " + inQuad + ".z\n" +
					"add " + uvCoord + ", " + uvCoord + ", " + temp + "\n";
			}
			
			registerCache.removeFragmentTempUsage(inQuad);
			
			code += "div " + uvCoord + ", " + uvCoord + ", " + uvCoord + ".w\n" +
				"mul " + uvCoord + ".xy, " + uvCoord + ".xy, " + dataReg + ".zw\n" +
				"add " + uvCoord + ".xy, " + uvCoord + ".xy, " + dataReg + ".zz\n";
			
			code += _baseMethod.getCascadeFragmentCode(shaderObject, methodVO, decReg, depthMapRegister, uvCoord, targetReg, registerCache, sharedRegisters) +
				"add " + targetReg + ".w, " + targetReg + ".w, " + dataReg + ".y\n";
			
			registerCache.removeFragmentTempUsage(uvCoord);
			
			return code;
		}
		
		/**
		 * @inheritDoc
		 */
        arcane override function activate(shaderObject:ShaderObjectBase, methodVO:MethodVO, stage:Stage3DProxy):void
		{
            stage.activateTexture(methodVO.texturesIndex, _castingLight.shadowMapper.depthMap as Texture2DBase);
			
			var vertexData:Vector.<Number> = shaderObject.vertexConstantData;
			var vertexIndex:int = methodVO.vertexConstantsIndex;

            shaderObject.vertexConstantData[methodVO.vertexConstantsIndex + 3] = -1/(_cascadeShadowMapper.depth*_epsilon);
			
			var numCascades:int = _cascadeShadowMapper.numCascades;
			vertexIndex += 4;
			for (var k:int = 0; k < numCascades; ++k) {
				_cascadeShadowMapper.getDepthProjections(k).copyRawDataTo(vertexData, vertexIndex, true);
				vertexIndex += 16;
			}
			
			var fragmentData:Vector.<Number> = shaderObject.fragmentConstantData;
			var fragmentIndex:int = methodVO.fragmentConstantsIndex;
			fragmentData[uint(fragmentIndex + 5)] = 1 - _alpha;
			
			var nearPlaneDistances:Vector.<Number> = _cascadeShadowMapper.nearPlaneDistances;
			
			fragmentIndex += 8;
			for (var i:uint = 0; i < numCascades; ++i)
				fragmentData[uint(fragmentIndex + i)] = nearPlaneDistances[i];
			
			_baseMethod.activateForCascade(shaderObject, methodVO, stage);
		}

		/**
		 * @inheritDoc
		 */

		arcane function setRenderState(shaderObject:ShaderObjectBase, methodVO:MethodVO, renderable:RenderableBase, stage:Stage3DProxy, camera:Camera3D):void
		{
		}

		/**
		 * Called when the shadow mappers cascade configuration changes.
		 */
		private function onCascadeChange(event:Event):void
		{
			invalidateShaderProgram();
		}

		/**
		 * Called when the base method's shader code is invalidated.
		 */
		private function onShaderInvalidated(event:ShadingMethodEvent):void
		{
			invalidateShaderProgram();
		}
	}
}