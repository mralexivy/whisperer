"""Regenerate the tiny deterministic Core ML fixture in PrivacyShieldTests.
Requires coremltools only when regenerating; test runs use the embedded protobuf.
This scales samples by 0.5 and is not an anti-transcription model.
"""
import base64
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.proto import FeatureTypes_pb2
builder = NeuralNetworkBuilder([('audio', datatypes.Array(1, 480))],
                               [('processed', datatypes.Array(1, 480))],
                               disable_rank5_shape_mapping=True)
builder.add_activation('half', 'LINEAR', 'audio', 'processed', params=[0.5, 0.0])
for feature in list(builder.spec.description.input) + list(builder.spec.description.output):
    feature.type.multiArrayType.dataType = FeatureTypes_pb2.ArrayFeatureType.FLOAT32
print(base64.b64encode(builder.spec.SerializeToString()).decode())
