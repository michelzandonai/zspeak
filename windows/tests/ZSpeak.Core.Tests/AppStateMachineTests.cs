using ZSpeak.Core.Models;

namespace ZSpeak.Core.Tests;

public sealed class AppStateMachineTests
{
    [Fact]
    public void FluxoCompleto_AceitaTransicoesDoP0()
    {
        var state = new AppStateMachine();

        state.TransitionTo(AppStatus.Ready);
        state.TransitionTo(AppStatus.Recording);
        state.TransitionTo(AppStatus.Transcribing);
        state.TransitionTo(AppStatus.Ready);

        Assert.Equal(AppStatus.Ready, state.Current);
    }

    [Fact]
    public void Loading_NaoPodeIrDiretoParaRecording()
    {
        var state = new AppStateMachine();

        Assert.Throws<InvalidOperationException>(() => state.TransitionTo(AppStatus.Recording));
    }
}
