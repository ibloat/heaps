package hxd.inspect;
import hxd.inspect.Property;

enum RendererSection {
	Core;
	Textures;
	Lights;
}

class SceneProps {

	var scene : h3d.scene.Scene;
	public var root : Node;

	public function new( scene ) {
		this.scene = scene;
		root = new Node("s3d");
		initRenderer();
	}

	function refresh() {
	}

	function addNode( name : String, icon : String, props : Void -> Array<Property>, ?parent : Node ) : Node {
		if( parent == null ) parent = root;
		var n = new Node(name, parent);
		n.props = props;
		return n;
	}

	function initRenderer() {
		var r = addNode("Renderer", "sliders", getRendererProps.bind(Core));
		addNode("Lights", "adjust", getRendererProps.bind(Lights), r);
		var s = addNode("Shaders", "code-fork", function() return [], r);
		addNode("Passes", "gears", getRendererProps.bind(Textures), r);

		var r = scene.renderer;
		var cl = Type.getClass(r);
		var ignoreList = getIgnoreList(cl);
		var fields = Type.getInstanceFields(cl);
		var meta = haxe.rtti.Meta.getFields(cl);
		fields.sort(Reflect.compare);
		var prev : { name : String, group : Array<{ name : String, v : Dynamic }> } = null;
		for( f in fields ) {
			if( ignoreList != null && ignoreList.indexOf(f) >= 0 ) continue;
			var m = Reflect.field(meta, f);
			if( m != null && Reflect.hasField(m, "ignore") ) continue;
			var v = Reflect.field(r, f);
			if( !Std.is(v, hxsl.Shader) && !Std.is(v, h3d.pass.ScreenFx) && !Std.is(v,Group) ) continue;

			if( prev != null && StringTools.startsWith(f, prev.name) ) {
				prev.group.push({ name : f.substr(prev.name.length), v : v });
				continue;
			}

			var subs = { name : f, group : [] };
			prev = subs;
			addNode(f, "circle", function() {
				var props = getDynamicProps(v);
				for( g in subs.group ) {
					var gp = getDynamicProps(g.v);
					if( gp.length == 1 )
						switch( gp[0] ) {
						case PGroup(_, props): gp = props;
						default:
						}
					props.push(PGroup(g.name, gp));
				}
				return props;
			}, s);
		}
	}

	public function getRendererProps( section : RendererSection ) {
		var props = [];

		var r = scene.renderer;

		switch( section ) {
		case Lights:

			var ls = scene.lightSystem;
			var props = [];
			props.push(PGroup("LightSystem",[
				PRange("maxLightsPerObject", 0, 10, function() return ls.maxLightsPerObject, function(s) ls.maxLightsPerObject = Std.int(s), 1),
				PColor("ambientLight", false, function() return ls.ambientLight, function(v) ls.ambientLight = v),
				PBool("perPixelLighting", function() return ls.perPixelLighting, function(b) ls.perPixelLighting = b),
			]));

			if( ls.shadowLight != null )
				props.push(PGroup("DirLight", getObjectProps(ls.shadowLight)));

			var s = Std.instance(r.getPass("shadow", false),h3d.pass.ShadowMap);
			if( s != null ) {
				props.push(PGroup("Shadows",[
					PRange("size", 64, 2048, function() return s.size, function(sz) s.size = Std.int(sz), 64),
					PColor("color", false, function() return s.color, function(v) s.color = v),
					PRange("power", 0, 100, function() return s.power, function(v) s.power = v),
					PRange("bias", 0, 0.1, function() return s.bias, function(v) s.bias = v),
					PGroup("blur", getDynamicProps(s.blur)),
				]));
			}

			return props;

		case Textures:

			var props = [];
			var tp = getTextures(@:privateAccess r.tcache);
			if( tp.length > 0 )
				props.push(PGroup("Textures",tp));

			var pmap = new Map();
			for( p in @:privateAccess r.allPasses ) {
				if( pmap.exists(p.p) ) continue;
				pmap.set(p.p, true);
				props.push(PGroup("Pass " + p.name, getPassProps(p.p)));
			}
			return props;

		case Core:

			var props = [];
			addDynamicProps(props, r, function(v) return !Std.is(v,hxsl.Shader) && !Std.is(v,h3d.pass.ScreenFx) && !Std.is(v,Group));
			return props;

		}
	}

	function getShaderProps( s : hxsl.Shader ) {
		var props = [];
		var data = @:privateAccess s.shader;
		var vars = data.data.vars.copy();
		vars.sort(function(v1, v2) return Reflect.compare(v1.name, v2.name));
		for( v in vars ) {
			switch( v.kind ) {
			case Param:

				if( v.qualifiers != null && v.qualifiers.indexOf(Ignore) >= 0 ) continue;

				var name = v.name+"__";
				function set(val:Dynamic) {
					Reflect.setField(s, name, val);
					if( hxsl.Ast.Tools.isConst(v) )
						@:privateAccess s.constModified = true;
				}
				switch( v.type ) {
				case TBool:
					props.push(PBool(v.name, function() return Reflect.field(s,name), set ));
				case TInt:
					var done = false;
					if( v.qualifiers != null )
						for( q in v.qualifiers )
							switch( q ) {
							case Range(min, max):
								done = true;
								props.push(PRange(v.name, min, max, function() return Reflect.field(s, name), set,1));
								break;
							default:
							}
					if( !done )
						props.push(PInt(v.name, function() return Reflect.field(s,name), set ));
				case TFloat:
					var done = false;
					if( v.qualifiers != null )
						for( q in v.qualifiers )
							switch( q ) {
							case Range(min, max):
								done = true;
								props.push(PRange(v.name, min, max, function() return Reflect.field(s, name), set));
								break;
							default:
							}
					if( !done )
						props.push(PFloat(v.name, function() return Reflect.field(s, name), set));
				case TVec(size = (3 | 4), VFloat) if( v.name.toLowerCase().indexOf("color") >= 0 ):
					props.push(PColor(v.name, size == 4, function() return Reflect.field(s, name), set));
				case TSampler2D, TSamplerCube:
					props.push(PTexture(v.name, function() return Reflect.field(s, name), set));
				case TVec(size, VFloat):
					props.push(PFloats(v.name, function() {
						var v : h3d.Vector = Reflect.field(s, name);
						var vl = [v.x, v.y];
						if( size > 2 ) vl.push(v.z);
						if( size > 3 ) vl.push(v.w);
						return vl;
					}, function(vl) {
						set(new h3d.Vector(vl[0], vl[1], vl[2], vl[3]));
					}));
				case TArray(_):
					props.push(PString(v.name, function() {
						var a : Array<Dynamic> = Reflect.field(s, name);
						return a == null ? "NULL" : "(" + a.length + " elements)";
					}, function(val) {}));
				default:
					props.push(PString(v.name, function() return ""+Reflect.field(s,name), function(val) { } ));
				}
			default:
			}
		}

		var name = data.data.name;
		if( StringTools.startsWith(name, "h3d.shader.") )
			name = name.substr(11);
		name = name.split(".").join(" "); // no dot in prop name !

		return PGroup("shader "+name, props);
	}

	function getMaterialShaderProps( mat : h3d.mat.Material, pass : h3d.mat.Pass, shader : hxsl.Shader ) {
		return getShaderProps(shader);
	}

	function getMaterialPassProps( mat : h3d.mat.Material, pass : h3d.mat.Pass ) {
		var pl = [
			PBool("Lights", function() return pass.enableLights, function(v) pass.enableLights = v),
			PEnum("Cull", h3d.mat.Data.Face, function() return pass.culling, function(v) pass.culling = v),
			PEnum("BlendSrc", h3d.mat.Data.Blend, function() return pass.blendSrc, function(v) pass.blendSrc = pass.blendAlphaSrc = v),
			PEnum("BlendDst", h3d.mat.Data.Blend, function() return pass.blendDst, function(v) pass.blendDst = pass.blendAlphaDst = v),
			PBool("DepthWrite", function() return pass.depthWrite, function(b) pass.depthWrite = b),
			PEnum("DepthTest", h3d.mat.Data.Compare, function() return pass.depthTest, function(v) pass.depthTest = v)
		];

		var shaders = [for( s in pass.getShaders() ) s];
		shaders.reverse();
		for( index in 0...shaders.length ) {
			var s = shaders[index];
			var p = getMaterialShaderProps(mat,pass,s);
			pl.push(p);
		}
		return PGroup("pass " + pass.name, pl);
	}

	function getMaterialProps( mat : h3d.mat.Material ) {
		var props = [];
		props.push(PString("name", function() return mat.name == null ? "" : mat.name, function(n) mat.name = n == "" ? null : n));
		for( pass in mat.getPasses() ) {
			var p = getMaterialPassProps(mat, pass);
			props.push(p);
		}
		return PGroup("Material",props);
	}

	function getLightProps( l : h3d.scene.Light ) {
		var props = [];
		props.push(PColor("color", false, function() return l.color, function(c) l.color.load(c)));
		props.push(PRange("priority", 0, 10, function() return l.priority, function(p) l.priority = Std.int(p),1));
		props.push(PBool("enableSpecular", function() return l.enableSpecular, function(b) l.enableSpecular = b));
		var dl = Std.instance(l, h3d.scene.DirLight);
		if( dl != null )
			props.push(PFloats("direction", function() return [dl.direction.x, dl.direction.y, dl.direction.z], function(fl) dl.direction.set(fl[0], fl[1], fl[2])));
		var pl = Std.instance(l, h3d.scene.PointLight);
		if( pl != null )
			props.push(PFloats("params", function() return [pl.params.x, pl.params.y, pl.params.z], function(fl) pl.params.set(fl[0], fl[1], fl[2], fl[3])));
		return PGroup("Light", props);
	}

	public function getObjectProps( o : h3d.scene.Object ) {
		var props = [];
		props.push(PString("name", function() return o.name == null ? "" : o.name, function(v) o.name = v == "" ? null : v));
		props.push(PFloat("x", function() return o.x, function(v) o.x = v));
		props.push(PFloat("y", function() return o.y, function(v) o.y = v));
		props.push(PFloat("z", function() return o.z, function(v) o.z = v));
		props.push(PBool("visible", function() return o.visible, function(v) o.visible = v));

		if( o.isMesh() ) {
			var multi = Std.instance(o, h3d.scene.MultiMaterial);
			if( multi != null && multi.materials.length > 1 ) {
				for( m in multi.materials )
					props.push(getMaterialProps(m));
			} else
				props.push(getMaterialProps(o.toMesh().material));

			var gp = Std.instance(o, h3d.parts.GpuParticles);
			if( gp != null )
				props = props.concat(getPartsProps(gp));

		} else {
			var c = Std.instance(o, h3d.scene.CustomObject);
			if( c != null )
				props.push(getMaterialProps(c.material));
			var l = Std.instance(o, h3d.scene.Light);
			if( l != null )
				props.push(getLightProps(l));
		}
		return props;
	}

	function getPartsProps( parts : h3d.parts.GpuParticles ) {
		var props = [];
		props.push(PInt("seed", function() return parts.seed, function(v) parts.seed = v));
		for( g in parts.getGroups() )
			props.push(getPartsGroupProps(parts, g));
		return props;
	}

	function getPartsGroupProps( parts : h3d.parts.GpuParticles, o : h3d.parts.GpuParticles.GpuPartGroup ) {
		var props = [];
		props.push(PGroup("Emitter", [
			PString("name", function() return o.name, function(v) { o.name = v; refresh(); }),
			PBool("enable", function() return o.enable, function(v) o.enable = v),
			PBool("loop", function() return o.emitLoop, function(v) { o.emitLoop = v; parts.currentTime = 0; }),
			PRange("sync", 0, 1, function() return o.emitSync, function(v) o.emitSync = v),
			PRange("delay", 0, 10, function() return o.emitDelay, function(v) o.emitDelay = v),
			PEnum("mode", h3d.parts.GpuParticles.GpuEmitMode, function() return o.emitMode, function(v) o.emitMode = v),
			PRange("count", 0, 1000, function() return o.nparts, function(v) o.nparts = Std.int(v), 1),
			PRange("distance", 0, 10, function() return o.emitDist, function(v) o.emitDist = v),
			PRange("angle", -90, 180, function() return Math.round(o.emitAngle*180/Math.PI), function(v) o.emitAngle = v*Math.PI/180, 1),
		]));

		props.push(PGroup("Life", [
			PRange("initial", 0, 10, function() return o.life, function(v) o.life = v),
			PRange("randomNess", 0, 1, function() return o.lifeRand, function(v) o.lifeRand = v),
			PRange("fadeIn", 0, 1, function() return o.fadeIn, function(v) o.fadeIn = v),
			PRange("fadeOut", 0, 1, function() return o.fadeOut, function(v) o.fadeOut = v),
			PRange("fadePower", 0, 3, function() return o.fadePower, function(v) o.fadePower = v),
		]));

		props.push(PGroup("Speed", [
			PRange("initial", 0, 10, function() return o.speed, function(v) o.speed = v),
			PRange("randomNess", 0, 1, function() return o.speedRand, function(v) o.speedRand = v),
			PRange("acceleration", -1, 1, function() return o.speedIncr, function(v) o.speedIncr = v),
			PRange("gravity", -5, 5, function() return o.gravity, function(v) o.gravity = v),
		]));

		props.push(PGroup("Size", [
			PRange("initial", 0.01, 2, function() return o.size, function(v) o.size = v),
			PRange("randomNess", 0, 1, function() return o.sizeRand, function(v) o.sizeRand = v),
			PRange("grow", -1, 1, function() return o.sizeIncr, function(v) o.sizeIncr = v),
		]));

		props.push(PGroup("Rotation", [
			PRange("init", 0, 1, function() return o.rotInit, function(v) o.rotInit = v),
			PRange("speed", 0, 5, function() return o.rotSpeed, function(v) o.rotSpeed = v),
			PRange("randomNess", 0, 1, function() return o.rotSpeedRand, function(v) o.rotSpeedRand = v),
		]));

		props.push(PGroup("Animation", [
			PTexture("diffuseTexture", function() return o.texture, function(v) o.texture = v),
			PEnum("blend", h3d.mat.BlendMode, function() return o.blendMode, function(v) o.blendMode = v),
			PRange("animationRepeat", 0, 10, function() return o.animationRepeat, function(v) o.animationRepeat = v),
			PRange("frameDivisionX", 1, 16, function() return o.frameDivisionX, function(v) o.frameDivisionX = Std.int(v), 1),
			PRange("frameDivisionY", 1, 16, function() return o.frameDivisionY, function(v) o.frameDivisionY = Std.int(v), 1),
			PRange("frameCount", 0, 32, function() return o.frameCount, function(v) o.frameCount = Std.int(v), 1),
			PTexture("colorGradient", function() return o.colorGradient, function(v) o.colorGradient = v),
		]));

		return PGroup(o.name, props);
	}

	function getDynamicProps( v : Dynamic ) : Array<Property> {
		if( Std.is(v,h3d.pass.ScreenFx) || Std.is(v,Group) ) {
			var props = [];
			addDynamicProps(props, v);
			return props;
		}
		var s = Std.instance(v, hxsl.Shader);
		if( s != null )
			return [getShaderProps(s)];
		var o = Std.instance(v, h3d.scene.Object);
		if( o != null )
			return getObjectProps(o);
		var s = Std.instance(v, hxsl.Shader);
		if( s != null )
			return [getShaderProps(s)];
		return null;
	}

	function getIgnoreList( c : Class<Dynamic> ) {
		var ignoreList = null;
		while( c != null ) {
			var cmeta : Dynamic = haxe.rtti.Meta.getType(c);
			if( cmeta != null ) {
				var ignore : Array<String> = cmeta.ignore;
				if( ignore != null ) {
					if( ignoreList == null ) ignoreList = [];
					for( i in ignore )
						ignoreList.push(i);
				}
			}
			c = Type.getSuperClass(c);
		}
		return ignoreList;
	}

	function addDynamicProps( props : Array<Property>, o : Dynamic, ?filter : Dynamic -> Bool ) {
		var cl = Type.getClass(o);
		var ignoreList = getIgnoreList(cl);
		var meta = haxe.rtti.Meta.getFields(cl);
		var fields = Type.getInstanceFields(cl);
		fields.sort(Reflect.compare);
		for( f in fields ) {

			if( ignoreList != null && ignoreList.indexOf(f) >= 0 ) continue;

			var v = Reflect.field(o, f);

			if( filter != null && !filter(v) ) continue;

			// @inspect metadata
			var m : Dynamic = Reflect.field(meta, f);

			if( m != null && Reflect.hasField(m, "ignore") )
				continue;

			if( m != null && Reflect.hasField(m, "inspect") ) {
				if( Std.is(v, Bool) )
					props.unshift(PBool(f, function() return Reflect.getProperty(o, f), function(v) Reflect.setProperty(o, f, v)));
				else if( Std.is(v, Float) ) {
					var range : Array<Null<Float>> = m.range;
					if( range != null )
						props.unshift(PRange(f, range[0], range[1], function() return Reflect.getProperty(o, f), function(v) Reflect.setProperty(o, f, v), range[2]));
					else
						props.unshift(PFloat(f, function() return Reflect.getProperty(o, f), function(v) Reflect.setProperty(o, f, v)));
				}
			} else {

				var pl = getDynamicProps(v);
				if( pl != null ) {
					if( pl.length == 1 && pl[0].match(PGroup(_)) )
						props.push(pl[0]);
					else
						props.push(PGroup(f, pl));
				}
			}
		}
	}

	function getPassProps( p : h3d.pass.Base ) {
		var props = [];
		var def = Std.instance(p, h3d.pass.Default);
		if( def == null ) return props;

		addDynamicProps(props, p);

		for( t in getTextures(@:privateAccess def.tcache) )
			props.push(t);

		return props;
	}

	function getTextures( t : h3d.impl.TextureCache ) {
		var cache = @:privateAccess t.cache;
		var props = [];
		for( i in 0...cache.length ) {
			var t = cache[i];
			props.push(PTexture(t.name, function() return t, null));
		}
		return props;
	}

	public function applyProps( propsValues : Dynamic, ?node : Node, ?onError : String -> Void ) {
		if( propsValues == null )
			return;
		if( node == null )
			node = root;
		var props = null;
		for( f in Reflect.fields(propsValues) ) {
			var v : Dynamic = Reflect.field(propsValues, f);
			var isObj = Reflect.isObject(v) && !Std.is(v, String) && !Std.is(v, Array);
			if( isObj ) {
				var n = node.getChildByName(f);
				if( n != null ) {
					applyProps(v, n, onError);
					continue;
				}
			}
			if( props == null ) {
				if( node.props == null ) {
					if( onError != null ) onError(node.getFullPath() + " has no properties");
					continue;
				}
				var pl = node.props();
				props = new Map();
				for( p in pl )
					props.set(PropManager.getPropName(p), p);
			}
			var p = props.get(f);
			if( p == null ) {
				if( onError != null ) onError(node.getFullPath() + " has no property "+f);
				continue;
			}
			switch( p ) {
			case PGroup(_, props) if( isObj ):
				applyPropsGroup(node.getFullPath()+"."+f, v, props, onError);
			default:
				PropManager.setPropValue(p, v);
			}
		}
	}

	function applyPropsGroup( path : String, propsValues : Dynamic, props : Array<Property>, onError : String -> Void ) {
		var pmap = new Map();
		for( p in props )
			pmap.set(PropManager.getPropName(p), p);
		for( f in Reflect.fields(propsValues) ) {
			var p = pmap.get(f);
			if( p == null ) {
				if( onError != null ) onError(path+" has no property "+f);
				continue;
			}
			var v : Dynamic = Reflect.field(propsValues, f);
			switch( p ) {
			case PGroup(_, props):
				applyPropsGroup(path + "." + f, v, props, onError);
			default:
				PropManager.setPropValue(p, v);
			}
		}
	}


}