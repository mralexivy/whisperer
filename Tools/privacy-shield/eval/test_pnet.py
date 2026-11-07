"""Streaming == batch, strict causality, and parameter count for PerturbNet."""
import torch
from pnet import PerturbNet, HOP

def test_stream_matches_batch_and_is_causal():
    torch.manual_seed(0)
    m = PerturbNet().eval()
    x = torch.randn(16000) * 0.1
    with torch.no_grad():
        batch = m(x.view(1, -1))[0]
    stream = m.stream(x)
    assert torch.allclose(batch, stream, atol=1e-5), (batch - stream).abs().max()
    # Causality: changing the future must not change earlier blocks (block t sees only samples < 160t).
    y = x.clone(); y[8000:] = torch.randn(8000)
    with torch.no_grad():
        b2 = m(y.view(1, -1))[0]
    assert torch.allclose(batch[:8000 + HOP], b2[:8000 + HOP], atol=1e-6)

def test_ahead_stream_matches_batch_and_sees_only_its_block():
    torch.manual_seed(0)
    m = PerturbNet(relative=0.6, ahead=1).eval()
    x = torch.randn(16000) * 0.1
    with torch.no_grad():
        batch = m(x.view(1, -1))[0]
    assert torch.allclose(batch, m.stream(x), atol=1e-5)
    # Block t may use block t itself, never block t+1: changing samples from 8000 on leaves [:8000] alone.
    y = x.clone(); y[8000:] = torch.randn(8000)
    with torch.no_grad():
        b2 = m(y.view(1, -1))[0]
    assert torch.allclose(batch[:8000], b2[:8000], atol=1e-6)
    assert not torch.allclose(batch[8000:8000 + HOP], b2[8000:8000 + HOP], atol=1e-6)

def test_size():
    n = sum(p.numel() for p in PerturbNet().parameters())
    assert n < 2_000_000, n
    print("params", n)

if __name__ == "__main__":
    test_stream_matches_batch_and_is_causal(); test_ahead_stream_matches_batch_and_sees_only_its_block(); test_size(); print("ok")
