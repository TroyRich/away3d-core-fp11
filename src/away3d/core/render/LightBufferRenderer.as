package away3d.core.render {
	import away3d.arcane;
	import away3d.core.managers.RTTBufferManager;
	import away3d.core.managers.Stage3DProxy;
	import away3d.core.traverse.EntityCollector;
	import away3d.entities.Camera3D;
	import away3d.lights.DirectionalLight;
	import away3d.lights.LightBase;
	import away3d.lights.PointLight;
	import away3d.materials.compilation.ShaderRegisterCache;
	import away3d.materials.compilation.ShaderRegisterElement;
	import away3d.materials.compilation.ShaderState;
	import away3d.textures.RectangleRenderTexture;
	import away3d.textures.Texture2DBase;

	import com.adobe.utils.AGALMiniAssembler;

	import flash.display3D.Context3D;
	import flash.display3D.Context3DBlendFactor;
	import flash.display3D.Context3DCompareMode;
	import flash.display3D.Context3DProfile;
	import flash.display3D.Context3DProgramType;
	import flash.display3D.Context3DTextureFilter;
	import flash.display3D.Context3DTextureFormat;
	import flash.display3D.Context3DVertexBufferFormat;
	import flash.display3D.IndexBuffer3D;
	import flash.display3D.Program3D;
	import flash.display3D.VertexBuffer3D;
	import flash.display3D.textures.RectangleTexture;
	import flash.geom.Vector3D;

	use namespace arcane;

	public class LightBufferRenderer {
		//attribute
		private static const POSITION_ATTRIBUTE:String = "aPos";
		private static const UV_ATTRIBUTE:String = "aUv";
		//varying
		private static const UV_VARYING:String = "vUv";

		private static const AMBIENT_VALUES_FC:String = "cfAmbientValues";
		private static const LIGHT_FC:String = "cfLightData";
		private static const CAMERA_FC:String = "cfCameraData";
		//texture
		private static const WORLD_NORMAL_TEXTURE:String = "tWorldNormal";
		private static const POSITION_TEXTURE:String = "tPosition";
		private static const DEPTH_TEXTURE:String = "tDepth";

		private static const _ambientValuesFC:Vector.<Number> = new Vector.<Number>();
		private static const _cameraFC:Vector.<Number> = new Vector.<Number>();
		private static const _scaleValuesVC:Vector.<Number> = Vector.<Number>([0, 0, 1, 1]);

		protected var programs:Vector.<Program3D>;
		protected var dirtyPrograms:Vector.<Boolean>;
		protected var shaderStates:Vector.<ShaderState>;

		private var _vertexCode:String;
		private var _fragmentCode:String;
		private var _shader:ShaderState;

		private var _textureRatioX:Number = 1;
		private var _textureRatioY:Number = 1;
		private var _camera:Camera3D;
		private var _monochromeSpecular:Boolean = false;
		private var _lightData:Vector.<Number> = new Vector.<Number>();

		private var _lights:Vector.<LightBase>;
		private var _numDirLights:uint = 0;
		private var _numPointLights:uint = 0;
		private var _specularEnabled:Boolean = true;

		protected var _registerCache:ShaderRegisterCache;
		private var _data:Vector.<Number>;
		private var cameraPositionReg:ShaderRegisterElement;
		private var ambientReg:ShaderRegisterElement;

		public function LightBufferRenderer() {

			initInstance();
		}

		private function initInstance():void {
			_registerCache = new ShaderRegisterCache(Context3DProfile.STANDARD);
			programs = new Vector.<Program3D>(8, true);
			dirtyPrograms = new Vector.<Boolean>(8, true);
			shaderStates = new Vector.<ShaderState>(8, true);
		}

		public function render(stage3DProxy:Stage3DProxy, entityCollector:EntityCollector, hasMRTSupport:Boolean, normalTexture:Texture2DBase, positionTexture:Texture2DBase):void {
			var i:int;
			//store data from collector
			_camera = entityCollector.camera;

			var rttBuffer:RTTBufferManager = RTTBufferManager.getInstance(stage3DProxy);
			var index:int = stage3DProxy.stage3DIndex;
			var context3D:Context3D = stage3DProxy.context3D;
			var vertexBuffer:VertexBuffer3D = (hasMRTSupport) ? rttBuffer.renderRectToScreenVertexBuffer : rttBuffer.renderToTextureVertexBuffer;
			var indexBuffer:IndexBuffer3D = rttBuffer.indexBuffer;

			var program:Program3D = programs[index];
			if (!program) {
				program = programs[index] = context3D.createProgram();
				dirtyPrograms[index] = true;
			}

			_shader = shaderStates[index];
			if (!_shader) {
				_shader = shaderStates[index] = new ShaderState();
			}

			//set point lights
			if (entityCollector.numDeferredDirectionalLights != _numDirLights || entityCollector.numDeferredPointLights != _numPointLights) {
				_lights = entityCollector.deferredLights;
				_numDirLights = entityCollector.numDeferredDirectionalLights;
				_numPointLights = entityCollector.numDeferredPointLights;
				dirtyPrograms[index] = true;
			}

			if (_numDirLights == 0 && _numPointLights == 0) return;

			if (dirtyPrograms[index]) {
				_shader.clear();
				compileVertexProgram();
				compileFragmentProgram();
				program.upload((new AGALMiniAssembler()).assemble(Context3DProgramType.VERTEX, _vertexCode, 2),
						(new AGALMiniAssembler()).assemble(Context3DProgramType.FRAGMENT, _fragmentCode, 2));
				dirtyPrograms[index] = false;
			}

			context3D.setProgram(program);

			//in future, enable stencil test optimization in FlashPlayer 15, when we don't need to clear it each time
			context3D.setVertexBufferAt(_shader.getAttribute(POSITION_ATTRIBUTE), vertexBuffer, 0, Context3DVertexBufferFormat.FLOAT_2);
			context3D.setVertexBufferAt(_shader.getAttribute(UV_ATTRIBUTE), vertexBuffer, 2, Context3DVertexBufferFormat.FLOAT_2);

			context3D.setTextureAt(_shader.getTexture(WORLD_NORMAL_TEXTURE), normalTexture.getTextureForStage3D(stage3DProxy));

			if (_shader.hasTexture(POSITION_TEXTURE)) {
				context3D.setTextureAt(_shader.getTexture(POSITION_TEXTURE), positionTexture.getTextureForStage3D(stage3DProxy));
			}

			//VERTEX DATA
			_scaleValuesVC[0] = _textureRatioX;
			_scaleValuesVC[1] = _textureRatioY;
			context3D.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 0, _scaleValuesVC, 1);

			//FRAGMENT DATA
			var globalAmbientR:Number = 0;
			var globalAmbientG:Number = 0;
			var globalAmbientB:Number = 0;
			var k:int = 0;
			var len:int = _numDirLights + _numPointLights;
			for (i = 0; i < len; i++) {
				var light:LightBase = _lights[i];
				var posDir:Vector3D;
				var radius:Number;
				var falloff:Number;
				if (light is PointLight) {
					radius = (light as PointLight)._radius;
					falloff = (light as PointLight)._fallOffFactor;
					posDir = light.scenePosition;
					_lightData[k++] = posDir.x;
					_lightData[k++] = posDir.y;
					_lightData[k++] = posDir.z;
				} else if (light is DirectionalLight) {
					posDir = (light as DirectionalLight).sceneDirection;
					var dx:Number = posDir.x;
					var dy:Number = posDir.y;
					var dz:Number = posDir.z;
					var nrm:Number = 1 / Math.sqrt(dx * dx + dy * dy + dz * dz);
					_lightData[k++] = -posDir.x * nrm;
					_lightData[k++] = -posDir.y * nrm;
					_lightData[k++] = -posDir.z * nrm;
				}

				_lightData[k++] = 1;
				_lightData[k++] = light._diffuseR;
				_lightData[k++] = light._diffuseG;
				_lightData[k++] = light._diffuseB;
				_lightData[k++] = radius;
				_lightData[k++] = light._specularR;
				_lightData[k++] = light._specularG;
				_lightData[k++] = light._specularB;
				_lightData[k++] = falloff;

				globalAmbientR += light._ambientR;
				globalAmbientG += light._ambientG;
				globalAmbientB += light._ambientB;
			}

			if (_shader.hasFragmentConstant(AMBIENT_VALUES_FC)) {
				_ambientValuesFC[0] = globalAmbientR;
				_ambientValuesFC[1] = globalAmbientG;
				_ambientValuesFC[2] = globalAmbientB;
				_ambientValuesFC[3] = 100;//decode gloss
				context3D.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, _shader.getFragmentConstant(AMBIENT_VALUES_FC), _ambientValuesFC, _shader.getFragmentConstantStride(AMBIENT_VALUES_FC));
			}

			if (_shader.hasFragmentConstant(CAMERA_FC)) {
				_cameraFC[0] = _camera.scenePosition.x;
				_cameraFC[1] = _camera.scenePosition.y;
				_cameraFC[2] = _camera.scenePosition.z;
				_cameraFC[3] = 1;
				context3D.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, _shader.getFragmentConstant(CAMERA_FC), _cameraFC, _shader.getFragmentConstantStride(CAMERA_FC));
			}

			if (_shader.hasFragmentConstant(LIGHT_FC)) {
				context3D.setProgramConstantsFromVector(Context3DProgramType.FRAGMENT, _shader.getFragmentConstant(LIGHT_FC), _lightData, _shader.getFragmentConstantStride(LIGHT_FC));
			}

			context3D.setBlendFactors(Context3DBlendFactor.ONE, Context3DBlendFactor.ZERO);
			context3D.drawTriangles(indexBuffer, 0, 2);

			context3D.setTextureAt(0, null);
			context3D.setTextureAt(1, null);
			context3D.setTextureAt(2, null);
		}

		private function compileFragmentProgram():void {
			_fragmentCode = "";

			//normal
			var normal:int = _shader.getFreeFragmentTemp();
			_fragmentCode += "tex ft" + normal + ", v" + _shader.getVarying(UV_VARYING) + ", fs" + _shader.getTexture(WORLD_NORMAL_TEXTURE) + " <2d,nearst,nomip,clamp>\n";

			if (_specularEnabled) {
				_fragmentCode += "mul ft" + normal + ".w, ft" + normal + ".w, fc" + _shader.getFragmentConstant(AMBIENT_VALUES_FC) + ".w\n";//100
				var position:int = _shader.getFreeFragmentTemp();
				_fragmentCode += "tex ft" + position + ", v" + _shader.getVarying(UV_VARYING) + ", fs" + _shader.getTexture(POSITION_TEXTURE) + " <2d,nearst,nomip,clamp>\n";
			}

			//diffuse
			var lightValues:int = _shader.getFragmentConstant(LIGHT_FC, 3);

			var lightDir:int = _shader.getFreeFragmentTemp();
			_fragmentCode += "sub ft" + lightDir + ", fc" + lightValues + ", ft" + position + "\n";
			_fragmentCode += "dp3 ft" + lightDir + ".w, ft" + lightDir + ", ft" + lightDir + "\n";
			_fragmentCode += "sub ft" + lightDir + ".w, ft" + lightDir + ".w, fc" + (lightValues + 1) + ".w\n";
			_fragmentCode += "mul ft" + lightDir + ".w, ft" + lightDir + ".w, fc" + (lightValues + 2) + ".w\n";
			_fragmentCode += "sub ft" + lightDir + ".w, fc" + (lightValues + 2) + ".w, ft" + lightDir + ".w\n";
			_fragmentCode += "nrm ft" + lightDir + ".xyz, ft" + lightDir + ".xyz\n";

			var diffuseLighting:int = _shader.getFreeFragmentTemp();
			_fragmentCode += "dp3 ft" + diffuseLighting + ".x, ft" + lightDir + ", ft" + normal + ".xyz\n";
			_fragmentCode += "sat ft" + diffuseLighting + ".x, ft" + diffuseLighting + ".x\n";
			_fragmentCode += "mul ft" + diffuseLighting + ".x, ft" + diffuseLighting + ".x, ft" + lightDir + ".w\n";
			_fragmentCode += "mul ft" + diffuseLighting + ".xyz, ft" + diffuseLighting + ".xxx, fc" + (lightValues + 1) + ".xyz\n";

			if (_specularEnabled) {
				var specular:int = _shader.getFreeFragmentTemp();
				_fragmentCode += "sub ft" + specular + ", fc" + _shader.getFragmentConstant(CAMERA_FC) + ", ft" + position + "\n";
				_fragmentCode += "nrm ft" + specular + ".xyz, ft" + specular + ".xyz\n";
				_fragmentCode += "add ft" + specular + ".xyz, ft" + specular + ".xyz, fc" + lightValues + ".xyz\n";
				_fragmentCode += "nrm ft" + specular + ".xyz, ft" + specular + "\n";
				_fragmentCode += "dp3 ft" + specular + ".x, ft" + normal + ", ft" + specular + "\n";
				_fragmentCode += "sat ft" + specular + ".x, ft" + specular + ".x\n";
				_fragmentCode += "pow ft" + specular + ".x, ft" + specular + ".x, ft" + normal + ".w\n";
				_fragmentCode += "mov oc, ft" + lightDir + ".wwww\n";
			} else {
				_fragmentCode += "mov oc, ft" + diffuseLighting + ".xyzz\n";
			}
		}

		private function compileVertexProgram():void {
			_vertexCode = "";
			_vertexCode += "mov op, va" + _shader.getAttribute(POSITION_ATTRIBUTE) + "\n";
			_vertexCode += "mov vt0, va" + _shader.getAttribute(UV_ATTRIBUTE) + "\n";
			_vertexCode += "mul vt0.xy, vt0.xy, vc0.xy\n";
			_vertexCode += "mov v" + _shader.getVarying(UV_VARYING) + ", vt0\n";
		}

		public function get textureRatioX():Number {
			return _textureRatioX;
		}

		public function set textureRatioX(value:Number):void {
			_textureRatioX = value;
		}

		public function get textureRatioY():Number {
			return _textureRatioY;
		}

		public function set textureRatioY(value:Number):void {
			_textureRatioY = value;
		}

		public function get monochromeSpecular():Boolean {
			return _monochromeSpecular;
		}

		public function set monochromeSpecular(value:Boolean):void {
			if (_monochromeSpecular == value) return;
			_monochromeSpecular = value;
			for (var i:uint = 0; i < 8; i++) {
				dirtyPrograms[i] = true;
			}
		}
	}
}