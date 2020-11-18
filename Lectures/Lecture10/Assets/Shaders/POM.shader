Shader "Custom/POM"
{
    Properties {
        // normal map texture on the material,
        // default to dummy "flat surface" normalmap
        [KeywordEnum(PLAIN, NORMAL, BUMP, POM, POM_SHADOWS)] MODE("Overlay mode", Float) = 0
        
        _NormalMap("Normal Map", 2D) = "bump" {}
        _MainTex("Texture", 2D) = "grey" {}
        _HeightMap("Height Map", 2D) = "white" {}
        _MaxHeight("Max Height", Range(0.0001, 0.02)) = 0.01
        _StepLength("Step Length", Float) = 0.000001
        _MaxStepCount("Max Step Count", Int) = 64
        
        _Reflectivity("Reflectivity", Range(1, 100)) = 0.5
    }
    
    CGINCLUDE
    #include "UnityCG.cginc"
    #include "UnityLightingCommon.cginc"
    
    inline float LinearEyeDepthToOutDepth(float z)
    {
        return (1 - _ZBufferParams.w * z) / (_ZBufferParams.z * z);
    }

    struct v2f {
        float3 worldPos : TEXCOORD0;
        half3 tspace0 : TEXCOORD1; // tangent.x, bitangent.x, normal.x
        half3 tspace1 : TEXCOORD2; // tangent.y, bitangent.y, normal.y
        half3 tspace2 : TEXCOORD3; // tangent.z, bitangent.z, normal.z
        half3 worldSurfaceNormal : TEXCOORD4;
        // texture coordinate for the normal map
        float2 uv : TEXCOORD5;
        float4 clip : SV_POSITION;
    };

    // Vertex shader now also gets a per-vertex tangent vector.
    // In Unity tangents are 4D vectors, with the .w component used to indicate direction of the bitangent vector.
    v2f vert (float4 vertex : POSITION, float3 normal : NORMAL, float4 tangent : TANGENT, float2 uv : TEXCOORD0)
    {
        v2f o;
        o.clip = UnityObjectToClipPos(vertex);
        o.worldPos = mul(unity_ObjectToWorld, vertex).xyz;
        half3 wNormal = UnityObjectToWorldNormal(normal);
        half3 wTangent = UnityObjectToWorldDir(tangent.xyz);
        
        o.uv = uv;
        o.worldSurfaceNormal = normal;
        
        // compute bitangent from cross product of normal and tangent and output it
        half tangentSign = tangent.w * unity_WorldTransformParams.w;
        half3 wBitangent = cross(wNormal, wTangent) * tangentSign;

        o.tspace0 = half3(wTangent.x, wBitangent.x, wNormal.x);
        o.tspace1 = half3(wTangent.y, wBitangent.y, wNormal.y);
        o.tspace2 = half3(wTangent.z, wBitangent.z, wNormal.z);
        
        return o;
    }

    // normal map texture from shader properties
    sampler2D _NormalMap;
    sampler2D _MainTex;
    sampler2D _HeightMap;
    
    // The maximum depth in which the ray can go.
    uniform float _MaxHeight;
    // Step size
    uniform float _StepLength;
    // Count of steps
    uniform int _MaxStepCount;
    
    float _Reflectivity;

    void frag (in v2f i, out half4 outColor : COLOR, out float outDepth : DEPTH)
    {
        float2 uv = i.uv;
        
        float3 worldViewDir = normalize(i.worldPos.xyz - _WorldSpaceCameraPos.xyz);
        float3x3 worldToTangent = transpose(float3x3(i.tspace0, i.tspace1, i.tspace2));
        float3 tangentViewDir = normalize(mul(worldToTangent, worldViewDir));
#if MODE_BUMP
        // Change UV according to the Parallax Offset Mapping
        float height = _MaxHeight - tex2D(_HeightMap, uv).r * _MaxHeight;
        float2 offset = tangentViewDir.xy / tangentViewDir.z * height;
        uv += offset;
#endif
    
        float depthDif = 0;
        float y;
#if MODE_POM | MODE_POM_SHADOWS    
        // Change UV according to Parallax Occclusion Mapping
        float2 curUV = uv;
        float curHeight = 0;
        float realHeight = _MaxHeight - tex2D(_HeightMap, curUV).r * _MaxHeight;
        float stepHeight = abs(tangentViewDir.z) * _StepLength;
        float2 deltaUV = tangentViewDir.xy * _StepLength;
        for (int stepsN = 0; stepsN < _MaxStepCount; ++stepsN)
        {
            if (curHeight < realHeight)
            {
                curHeight += stepHeight;
                curUV += deltaUV;
                realHeight = _MaxHeight - tex2D(_HeightMap, curUV).r * _MaxHeight;
            }    
        }
        float ph = curHeight - stepHeight;
        float2 prevUV = curUV - deltaUV;
        float phr = _MaxHeight - tex2D(_HeightMap, prevUV).r * _MaxHeight;
        float h = curHeight;
        float hr = realHeight;
        float x = (ph - phr) / (hr - phr - h + ph);
        if (x > 1 || x < 0) x = 0.5;
        uv = (1 - x) * curUV + x * prevUV;
#endif

        float3 worldLightDir = normalize(_WorldSpaceLightPos0.xyz);
        float shadow = 0;
#if MODE_POM_SHADOWS
        // Calculate soft shadows according to Parallax Occclusion Mapping, assign to shadow
#endif
        
        half3 normal = i.worldSurfaceNormal;
#if !MODE_PLAIN
        // Implement Normal Mapping
        half3 tnormal = UnpackNormal(tex2D(_NormalMap, uv));
        normal.x = dot(i.tspace0, tnormal);
        normal.y = dot(i.tspace1, tnormal);
        normal.z = dot(i.tspace2, tnormal);
#endif

        // Diffuse lightning
        half cosTheta = max(0, dot(normal, worldLightDir));
        half3 diffuseLight = max(0, cosTheta) * _LightColor0 * max(0, 1 - shadow);
        
        // Specular lighting (ad-hoc)
        half specularLight = pow(max(0, dot(worldViewDir, reflect(worldLightDir, normal))), _Reflectivity) * _LightColor0 * max(0, 1 - shadow); 

        // Ambient lighting
        half3 ambient = ShadeSH9(half4(UnityObjectToWorldNormal(normal), 1));

        // Return resulting color
        float3 texColor = tex2D(_MainTex, uv);
        //outColor = half4(y, y, y, 0);
        outColor = half4((diffuseLight + specularLight + ambient) * texColor, 0);
        outDepth = LinearEyeDepthToOutDepth(LinearEyeDepth(i.clip.z));
    }
    ENDCG
    
    SubShader
    {    
        Pass
        {
            Name "MAIN"
            Tags { "LightMode" = "ForwardBase" }
        
            ZTest Less
            ZWrite On
            Cull Back
            
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #pragma multi_compile_local MODE_PLAIN MODE_NORMAL MODE_BUMP MODE_POM MODE_POM_SHADOWS
            ENDCG
            
        }
    }
}