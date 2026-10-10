public struct SceneData {
    public float4x4 proj_view;
    public float4x4 inverse_proj_rotation;
    public float3 to_sun;
    public float time;
    public float3 camera_position;
    public float planet_radius;
    public float4 light_color;
    public float4 camera_up;
    public float4 sky_zenith;
    public float4 sky_horizon;
};
[[vk::binding(0, 0)]]
public ConstantBuffer<SceneData> scene_data;

